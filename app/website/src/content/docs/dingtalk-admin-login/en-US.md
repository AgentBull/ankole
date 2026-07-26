---
title: Admin sign-in with DingTalk
description: Configure DingTalk as the admin identity provider — the same robot's credentials, OIDC with corpid scope, organization-structure directory sync over the Stream WebSocket, and the credential-check capability unique to this adapter.
section: Guides
order: 324
---

This guide federates Console admin sign-in to DingTalk. By the end, admins sign into Ankole with their DingTalk work account, organization structure (departments and users) syncs into AuthZ, and the setup has reused the same `clientId`/`clientSecret` your chat robot uses. It is the identity face of the [DingTalk adapter](../adapters-dingtalk/); this page is the operator walkthrough for that face, mirroring [Lark](../lark-admin-login/) and [Slack](../slack-admin-login/) admin login.

The decisive property, stated up front: DingTalk's identity face carries five capabilities — the same four as the other chat-platform IdPs (`oidc_authorization`, `oidc_code_exchange`, `directory_full_sync`, `directory_realtime_sync`), plus `credential_check`, which is unique to this adapter. Realtime sync rides the Stream WebSocket (the same `clientId`/`clientSecret` the chat face uses), so it needs no public ingress. And one credential pair does everything — chat, OIDC, and directory — which is why DingTalk is the simplest IdP to configure of the chat platforms.

## What you need in DingTalk

One enterprise-internal robot does both the chat binding and the identity face — the same `clientId`/`clientSecret` from [Your first DingTalk bot](../dingtalk-first-bot/). What the identity face adds on the DingTalk side:

- **OIDC redirect URL**, configured in the robot's developer console, pointing at the Ankole Console callback. DingTalk matches the redirect exactly.
- **Login and directory scopes**, granted to the robot — the OIDC scope (`openid corpid` by default) and the contact/department read permissions the directory sync needs.
- **A published robot version** containing the redirect URL, scopes, and test-user availability. Unpublished settings do not apply.

No second OAuth client, no service account, no separate bot token — the same credential pair that doubles as Stream credentials also authenticates OIDC and reads the directory. This is the one-credential design that sets DingTalk apart from Lark (separate `appID`/`appSecret`) and Slack (separate `clientID`/`clientSecret`).

## Configure the identity provider

Create the identity provider through the setup flow or the Console:

```bash
curl -X PUT https://ankole.example.com/api/v1/identity-providers/dingtalk-main \
  -H "Authorization: Bearer $CONSOLE_TOKEN" \
  -H "Content-Type: application/json" \
  -d '{
    "adapter_id": "dingtalk",
    "clientId": "<app-key>",
    "clientSecret": "<app-secret>",
    "oidc": { "enabled": true, "scope": "openid corpid" },
    "sync": { "contacts": true, "websocket": true, "pageSize": 50 }
  }'
```

The fields the adapter validates:

| Field | Required | Meaning |
|---|---|---|
| `clientId` | yes | the robot's AppKey — same as the chat face's |
| `clientSecret` | yes | the robot's AppSecret (encrypted at rest) |
| `oidc.enabled` | default true | whether OIDC sign-in is active |
| `oidc.scope` | default `openid corpid` | the OIDC scope to request |
| `sync.contacts` | default true | whether directory sync runs |
| `sync.websocket` | default true | whether realtime sync uses the Stream WebSocket |
| `sync.pageSize` | default 50 | the directory page size (1–100) |

Every pattern is encrypted; `clientSecret` is secret material. The `clientId`/`clientSecret` here are the same values the chat binding uses — one robot, one credential pair, two faces.

## The login flow

DingTalk OIDC: redirect to DingTalk's authorization endpoint, exchange the code, read the user's identity. The `oidc.scope` of `openid corpid` carries the user's open id and their corporation id — the `corpid` is what ties the user to your DingTalk organization, and it is the scope's reason for being there. The adapter resolves the user to an Ankole Principal; the first successful user becomes this installation's root administrator and the activation code expires.

The boundary is the DingTalk organization (the `corpid`). A user from another organization's DingTalk does not share your `corpid` and does not authenticate. This is DingTalk's equivalent of Lark's app-availability-scope and Slack's `teamID`.

## The `credential_check` capability

DingTalk's identity face declares `credential_check` alongside the standard four capabilities. This is the adapter's ability to validate the `clientId`/`clientSecret` pair against DingTalk before relying on them — a preflight that catches a bad credential pair at configuration time, not at the first login attempt. It is unique to this adapter; the others discover a bad credential when a login or sync fails.

## Directory sync (full + realtime)

With `sync.contacts` on, the adapter pulls DingTalk's organization structure — departments and users — into AuthZ groups. Two shapes:

- **Full sync** (`directory_full_sync`) reads the directory through the DingTalk API on a cadence, paging at `sync.pageSize` (1–100, default 50).
- **Realtime sync** (`directory_realtime_sync`) rides the Stream WebSocket the chat face uses. When a department or user changes in DingTalk, the event arrives over the same connection — no public webhook, no Graph subscription, no second ingress.

After the first sync, DingTalk departments and user memberships exist as Ankole AuthZ groups. Assign grants to them through [Principal and AuthZ](../principal-authz/) — "everyone in this DingTalk department can administer these agents" is a real grant, with DingTalk as the source of truth.

## Verify the login and the sync

Sign in through the Console's DingTalk path with a user in the organization. A successful login resolves to an Ankole Principal.

Then verify the sync:

- **Full sync** — after the first run, check `/principal-groups` for the DingTalk departments and members.
- **Realtime sync** — add or move a user in DingTalk's organization structure and watch `/principal-groups` update. If it does not, the Stream connection may not be established — confirm the robot is enabled and the `clientId`/`clientSecret` are valid.

## When something does not work

- **Login fails at the redirect** — the robot's redirect URL does not match the Ankole Console callback. DingTalk matches exactly.
- **Login fails for a valid user** — the user is in a different DingTalk organization (different `corpid`), or the robot version is unpublished.
- **`credential_check` fails at configuration** — the `clientId`/`clientSecret` pair is wrong. This is the preflight catching it early; correct the credentials before proceeding.
- **Directory sync returns empty** — the contact/department read scopes are not granted, or the `clientId` lacks them. DingTalk caches app tokens per credential set; a recently rotated `clientSecret` may need a refresh cycle.
- **Realtime sync is stale** — the Stream connection has not established. Confirm the robot is enabled and the control plane has outbound internet.

## How this differs from the other IdP guides

- **vs Lark** — same long-connection realtime model. Lark uses the Feishu WebSocket; DingTalk uses the Stream API. DingTalk adds `credential_check` and the one-credential design; Lark uses a separate `appID`/`appSecret`.
- **vs Slack** — same Socket-Mode-style realtime. Slack's identity face adds a separate OAuth client; DingTalk reuses the robot's `clientId`/`clientSecret`.
- **vs Entra ID** — Entra ID realtime uses Graph subscriptions with a reconciler; DingTalk uses the Stream WebSocket, simpler.
- **vs Google Workspace** — Google Workspace has full sync only; DingTalk has both.
- **vs the chat binding** — one robot serves both, with one credential pair. The identity face adds the redirect URL and directory scopes; the chat face adds the event subscriptions and card template.

## What this guide is not

It is not a DingTalk developer-console tutorial — the console changes, and the exact scope names are DingTalk's to document. It is not a way to admit users from other DingTalk organizations; the `corpid` is the boundary. And it is not separate from the chat face; one robot, one credential pair, two faces.

## Next steps

- For the adapter reference (both faces), read the [DingTalk adapter](../adapters-dingtalk/) page.
- For the chat face of the same robot, read [Your first DingTalk bot](../dingtalk-first-bot/).
- For the permission model the synced groups feed into, read [Principal and AuthZ](../principal-authz/).
