---
title: Admin sign-in with Slack
description: Configure Slack as the admin identity provider — the OAuth client, the team boundary, workspace directory sync, and the optional bot tokens the identity face can reuse.
section: Guides
order: 323
---

This guide federates Console admin sign-in to a Slack workspace. By the end, admins sign into Ankole with their Slack account, workspace membership syncs into AuthZ, and the setup has used Slack's OIDC over the same Socket Mode connection the chat face uses. It is the identity face of the [Slack adapter](../adapters-slack/); this page is the operator walkthrough for that face, mirroring [Lark admin login](../lark-admin-login/).

The decisive property, stated up front: Slack's identity face carries the same four capabilities as Lark and Entra ID — `oidc_authorization`, `oidc_code_exchange`, `directory_full_sync`, `directory_realtime_sync`. Realtime sync rides the Socket Mode connection (the same `appToken` the chat face uses), so it needs no public ingress. The adapter also owns Slack workspace membership as a projection — Slack is the source of truth, and membership changes propagate as the connection carries them.

## What you need in Slack

One Slack app does both the chat binding and the identity face — the same app from [Your first Slack bot](../slack-first-bot/). What the identity face adds:

- **An OAuth client** — the app's `clientID` and `clientSecret`, from the Slack API dashboard's *Basic Information*. These are separate from the chat face's `botToken`/`appToken`, though all four live in the same app.
- **The OIDC redirect URL**, added to the app's *OAuth & Permissions* redirect URLs. For local development, the Ankole Console callback; for a production host, your real HTTPS origin.
- **OIDC scopes** — `openid`, `email`, `profile`, and the identity scopes Slack requires. The adapter's default scope set covers the standard sign-in; extend it only if you need additional claims.
- **Directory read scopes** — the workspace membership read permissions (`users:read`, `users:read.email`, `team:read`) so the adapter can project who is in the workspace.
- **Socket Mode enabled** — the realtime sync uses the same app-level WebSocket as the chat face. No Socket Mode, no realtime directory sync.

The identity face can optionally reuse the chat face's `botToken` and `appToken` — the adapter's identity config accepts them, with the same `xoxb-`/`xapp-` prefix rules. If your chat binding already has them, pointing the identity face at the same tokens means one Socket Mode connection serves both.

## Configure the identity provider

Create the identity provider through the setup flow or the Console:

```bash
curl -X PUT https://ankole.example.com/api/v1/identity-providers/slack-main \
  -H "Authorization: Bearer $CONSOLE_TOKEN" \
  -H "Content-Type: application/json" \
  -d '{
    "adapter_id": "slack",
    "clientID": "<oauth-client-id>",
    "clientSecret": "<oauth-client-secret>",
    "teamID": "<team-id>",
    "botToken": "<xoxb-bot-token>",
    "appToken": "<xapp-app-token>",
    "oidc": { "enabled": true },
    "sync": { "contacts": true }
  }'
```

The fields the adapter validates:

| Field | Required | Meaning |
|---|---|---|
| `clientID` | yes | the OAuth client id |
| `clientSecret` | yes | the OAuth client secret (encrypted at rest) |
| `teamID` | optional | the workspace team id; scopes sign-in to this workspace |
| `botToken` | optional | a `xoxb-` token, for directory reads; reuses the chat face's if same |
| `appToken` | optional | a `xapp-` token, for Socket Mode realtime sync |
| `oidc.enabled` | default true | whether OIDC sign-in is active |
| `oidc.scopes` | default set | the OIDC scopes to request |
| `sync.contacts` | default true | whether directory sync runs |

`botToken` and `appToken` on the identity face must obey the same prefix rules as the chat face (`xoxb-` and `xapp-`), or the adapter rejects them with `invalid_token_prefix`. Every pattern is encrypted.

## The login flow

Standard Slack OIDC: redirect to Slack's authorization endpoint, exchange the code, read the user's identity from the token. The adapter resolves the user to an Ankole Principal; the first successful user becomes this installation's root administrator and the activation code expires.

The boundary is the workspace. `teamID`, when set, scopes sign-in to that workspace — a user from another workspace's token does not authenticate. This is Slack's equivalent of Lark's app-availability-scope boundary and Google Workspace's `allowedDomains`.

## Directory sync (full + realtime)

With `sync.contacts` on, the adapter pulls Slack workspace membership into AuthZ groups. Two shapes:

- **Full sync** (`directory_full_sync`) reads the workspace roster through the Slack API on a cadence.
- **Realtime sync** (`directory_realtime_sync`) rides the Socket Mode connection the chat face uses. When membership changes in Slack, the event arrives over the same `appToken`-opened WebSocket — no public webhook, no Graph subscription.

The adapter owns Slack directory membership projection: Slack is the source of truth, and Ankole's view converges to it. After the first sync, workspace groups and user memberships exist as Ankole AuthZ groups, and you assign grants to them through [Principal and AuthZ](../principal-authz/).

## Verify the login and the sync

Sign in through the Console's Slack path with a workspace member. A successful login resolves to an Ankole Principal.

Then verify the sync:

- **Full sync** — after the first run, check `/principal-groups` for the workspace's groups and members.
- **Realtime sync** — invite or remove a member in Slack and watch `/principal-groups` update. If it does not, Socket Mode may not be connected — confirm the app's Socket Mode is enabled and the `appToken` starts with `xapp-`.

## When something does not work

- **Login fails at the redirect** — the app's redirect URLs do not include the Ankole Console callback, or `clientID` does not match.
- **Login fails for a valid workspace member** — `teamID` is set and the user is in a different workspace, or the OIDC scopes are not granted.
- **Directory sync returns empty** — the directory read scopes (`users:read`, `team:read`) are not granted, or the `botToken` lacks them.
- **Realtime sync is stale** — Socket Mode is not connected. Confirm the app's Socket Mode is enabled, `appToken` is present and `xapp-`-prefixed, and the control plane has outbound internet.

## How this differs from the other IdP guides

- **vs Lark** — same four capabilities and same long-connection realtime model. Lark uses the Feishu long-connection WebSocket; Slack uses Socket Mode. Both need no public ingress.
- **vs Entra ID** — Entra ID realtime uses Graph subscriptions with a reconciler and `clientState`; Slack uses Socket Mode, simpler to run.
- **vs Google Workspace** — Google Workspace has full sync only; Slack has both.
- **vs the chat binding** — one app serves both. The identity face adds the OAuth client and directory scopes; the chat face adds the event subscriptions and message scopes. The optional `botToken`/`appToken` are shared when the two faces use the same tokens.

## What this guide is not

It is not a Slack app-configuration tutorial — the dashboard changes, and the exact scope names are Slack's to document. It is not a way to admit users from other workspaces; the workspace (optionally pinned by `teamID`) is the boundary. And it is not separate from the chat face; one app serves both, and the Socket Mode connection is shared.

## Next steps

- For the adapter reference (both faces), read the [Slack adapter](../adapters-slack/) page.
- For the chat face of the same app, read [Your first Slack bot](../slack-first-bot/).
- For the permission model the synced groups feed into, read [Principal and AuthZ](../principal-authz/).
