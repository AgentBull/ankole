---
title: DingTalk adapter
description: Connect an agent to DingTalk — the enterprise-internal app, the Stream connection, AI card replies, markdown rendering, and the OIDC identity provider for admin sign-in.
section: User guide
order: 16
---

The DingTalk adapter connects an Ankole agent to DingTalk. It carries two faces: a chat binding that reads robot messages and replies through AI cards, and an identity-provider face that signs admins into the Console through DingTalk OIDC. Both faces ride one Stream long connection, and both faces use the same AppKey/AppSecret pair. This page is the operator setup path.

## What the adapter declares

`Ankole.Plugins.DingTalkAdapter` (`plugin_id: "dingtalk-adapter"`) declares two adapter declarations:

- **`signals_gateway.adapter`** (`id: "dingtalk"`) — the chat face, the "trimmed chat face". A signal binding routes DingTalk messages and card callbacks to an agent.
- **`principals.identity_provider`** (`id: "dingtalk"`) — the identity face. DingTalk OIDC serves as the admin identity provider, and a directory sync pulls DingTalk contacts into AuthZ.

The chat face is trimmed to what the DingTalk robot API actually offers: group messages arrive only when the robot is @-mentioned or DMed (`addressed_only`), and there are no reaction, edit, or recall inbound events. Enabling the DingTalk plugin makes both faces available.

## Prerequisites

Create an **enterprise-internal app** in the DingTalk developer console. The app's credentials give you the two values the chat config needs, and the same values do double duty:

| Field | Meaning |
|---|---|
| `clientId` | the app's AppKey, from *Basic information > Credentials*. The same value is the Stream `clientId`. |
| `clientSecret` | the app's AppSecret, from the same page; stored encrypted by the control plane. The same value is the Stream `clientSecret`. |

The robot's own encrypted id arrives on the stream, so you do not hand the adapter a bot identity — the adapter resolves it from the inbound frames, the same way the Lark adapter does. The optional `cardTemplateId` selects the AI card template the binding streams into; leave it empty and AI replies degrade to plain Markdown.

## The one-binding constraint

This is the limit operators trip on first. DingTalk runs one Stream long connection per AppKey/AppSecret pair, and that pair is shared by the chat face and the identity face. Two rules follow, and the adapter enforces both at binding-write time:

- **One agent gets at most one enabled DingTalk binding.** A second enabled DingTalk binding on the same agent is rejected (`dingtalk_binding_already_exists`).
- **One `clientId` cannot be assigned to two agents.** A second agent that reuses an enabled binding's `clientId` is rejected (`dingtalk_app_already_bound`).

Updating the current binding is allowed, and a disabled binding does not reserve the app — the constraint is about *enabled* bindings. Treat the AppKey/AppSecret pair as a single-tenant resource: one robot, one agent.

## Create a chat binding

```bash
curl -X PUT https://ankole.example.com/api/v1/agents/<agent_uid>/signal-bindings/dingtalk/<binding_name> \
  -H "Authorization: Bearer $CONSOLE_TOKEN" \
  -H "Content-Type: application/json" \
  -d '{ "config_ref": "...", "filters": { ... }, "unaddressed_group_message_policy": "..." }'
```

The binding's `config_ref` points at the DingTalk app configuration (the `signals_gateway.dingtalk.bindings.<id>` AppConfigure key). See [Signal bindings](../signal-bindings/) for the filter and group-message-policy fields shared by all adapters.

## The Stream model

DingTalk does not push events over an HTTP webhook. The adapter holds one long-lived Stream connection per AppKey/AppSecret pair (`connection_key` is `{"dingtalk", clientId}`), and the chat face and the identity face share it. Because the credentials double as the Stream `clientId`/`clientSecret`, there is no second secret to provision — the AppKey/AppSecret that authenticate API calls are the same pair that opens the stream.

App tokens are cached per credential set. A token rotation takes effect on the next token refresh, not immediately; if you rotate `clientSecret`, the cached token is stale until that refresh runs.

## Replies: AI cards and markdown

The agent replies through DingTalk's AI-card delivery, with a Markdown fallback. The adapter renders model output into the card shape DingTalk's card platform expects and streams it through `PUT /v1.0/card/streaming`; the card template lives under `priv/card_template/`, and the operator builds it once per DingTalk organization and pastes its `cardTemplateId` into the binding. An empty `cardTemplateId` disables card streaming and AI replies degrade to plain Markdown messages.

Markdown segmenting is adapter-owned because DingTalk's Markdown has its own constraints. If a model reply contains content DingTalk cannot render verbatim, the adapter's Markdown segmenter reconciles it; a reply that still looks wrong usually means the model produced something outside DingTalk's supported Markdown subset.

## DingTalk as the admin identity provider

The identity face lets admins sign into the Console with their DingTalk account. Configure it through the identity-provider surface, with `adapter_id: "dingtalk"`:

```bash
curl -X PUT https://ankole.example.com/api/v1/identity-providers/<provider_id> \
  -H "Authorization: Bearer $CONSOLE_TOKEN" \
  -H "Content-Type: application/json" \
  -d '{ "adapter_id": "dingtalk", "oidc": { "enabled": true, "scope": "openid corpid" } }'
```

The app must have a released version, and the login callback URL must be registered in the app's *Development configuration > Security settings > Redirect URL*; DingTalk refuses browser login for an app it cannot find. After login, a directory sync (`sync.contacts`) pulls DingTalk contacts, department groups, and memberships into AuthZ, with an incremental contact-change stream (`sync.websocket`) on top.

## When something does not work

The common failures are config-shaped, not code-shaped:

- **Validation fails on `clientId` / `clientSecret`** — both are required strings; a blank or missing value fails `validate_chat_config`. Copy the AppKey/AppSecret from *Basic information > Credentials* of the enterprise-internal app.
- **The robot does not reply** — confirm the robot is subscribed to the right events, the test user and conversation are in scope, the binding is enabled, the agent has usable model profiles, and the Stream connection is up. The [FAQ](../faq/) troubleshooting order applies.
- **A stale token after rotation** — app tokens are cached per credential set, so a rotated `clientSecret` does not take effect until the next token refresh.
- **The second binding is rejected** — this is the one-binding constraint, not a bug. One agent holds at most one enabled DingTalk binding, and one `clientId` serves at most one agent. Disable or reassign before adding a second.

## Next steps

- For the binding model, read [Signal bindings](../signal-bindings/).
- For the identity-provider routes, read the [Console API reference](../console-api/).
- For the inbound pipeline, read the [SignalsGateway](../signals-gateway/) developer page.
