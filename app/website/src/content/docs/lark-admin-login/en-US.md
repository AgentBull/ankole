---
title: Admin sign-in with Lark or Feishu
description: Configure Lark or Feishu as the admin identity provider — the self-built app's OIDC, IM-group directory sync over the long connection, and the redirect-URL exactness the setup depends on.
section: Guides
order: 322
---

This guide federates Console admin sign-in to Lark or Feishu. By the end, admins sign into Ankole with their Lark account, directory groups (IM groups and org structure) sync into AuthZ, and the setup has used the same self-built app your chat bot uses. It is the identity face of the [Lark adapter](../adapters-lark/); this page is the operator walkthrough for that face alone.

The decisive property, stated up front: Lark's identity face carries the same four capabilities as the Entra ID face — `oidc_authorization`, `oidc_code_exchange`, `directory_full_sync`, `directory_realtime_sync`. Realtime sync runs over the Lark long-connection WebSocket, not Graph subscriptions, so it needs no public ingress — the same outbound connection the chat face uses carries directory changes too. This is why Lark-as-IdP is the simplest of the three realtime-sync adapters to run.

## What you need in Lark

One self-built enterprise app does both the chat binding and the identity face — the same `appID`/`appSecret` you used in [Your first Lark bot](../lark-first-bot/). What the identity face needs on top:

- **The OIDC redirect URL**, added to the app's security settings. For local development, `http://localhost:4000/sessions/oidc/lark-main/callback`. For a production host, your real HTTPS origin. Lark requires an exact match between the request's `redirect_uri` and the allowlist — and `localhost` and `127.0.0.1` are different redirect URIs, so use the documented form unless you also update the allowlist entry.
- **Directory and login scopes**, granted through Feishu's bulk-import or the permissions screen: `auth:user_access_token:read`, `contact:contact.base:readonly`, `contact:department.base:readonly`, `contact:department.organize:readonly`, `contact:user.base:readonly`, `contact:user.department:readonly`, `contact:user.email:readonly`. These let the adapter read who the user is and what groups and departments they belong to.
- **A published app version.** Unpublished settings do not apply to the test user; publish a version that contains the redirect URLs, scopes, and test-user availability before you sign in.

## Configure the identity provider

Create the identity provider through the setup flow (on first setup) or the Console:

| Field | Value |
|---|---|
| Provider ID | `lark-main` |
| Domain | Feishu (or Lark, for the international domain) |
| App ID | the self-built app's App ID |
| App Secret | the self-built app's App Secret |
| OIDC | Enabled |
| Directory sync | Enabled |
| WebSocket incremental sync | Enabled |

Enter the App Secret in the browser — a coding agent should never request, read, repeat, or store it. Choose the action that saves the provider and signs in with OIDC. After the human completes Lark authorization, the first successful user becomes this installation's root administrator and the activation code expires.

Saving the provider also opens the outbound WebSocket long-connection from the control plane — it needs internet access, but no public IP, reverse proxy, or tunnel. This is the same connection the chat face uses; one owner per app.

## The login flow

Standard Lark OIDC: redirect to Lark's authorization endpoint, exchange the returned code for a user access token, read the user's identity. The adapter resolves the user to an Ankole Principal. There is no `allowedDomains` boundary to configure — the boundary is the app's availability scope (which users the app is published to), set in the Lark developer console, not in Ankole. A user outside the app's scope cannot authenticate.

## Directory sync (full + realtime)

With directory sync enabled, the adapter pulls Lark's directory — IM groups, departments, and users — into AuthZ groups. Two sync shapes:

- **Full sync** (`directory_full_sync`) reads the directory through the Lark API on a cadence, converging Ankole's view to Lark's truth.
- **Realtime sync** (`directory_realtime_sync`) rides the long-connection WebSocket. When a group or department changes in Lark, the event arrives over the same connection the chat face uses — no public webhook, no Graph subscription, no second ingress. The `sync_im_groups` and `refresh_im_group` jobs keep the mirror current.

After the first sync, Lark IM groups exist as Ankole AuthZ groups. Assign grants to them through [Principal and AuthZ](../principal-authz/) — "everyone in this Lark IM group can administer these agents" is a real grant, with Lark as the source of truth.

## Verify the login and the sync

Sign in through the Console's Lark path with a user in the app's availability scope. A successful login resolves to an Ankole Principal.

Then verify the sync:

- **Full sync** — after the first run, check `/principal-groups` for the Lark IM groups and departments.
- **Realtime sync** — add or remove a user from an IM group in Lark and watch `/principal-groups` update. If it does not, the long connection may not be established yet — Feishu sometimes rejects long-connection events before it detects the client. Keep the control plane running and retry; the connection establishes on its own.

## When something does not work

- **Login fails with a redirect mismatch** — confirm the browser origin, provider id, and Lark allowlist produce exactly the documented callback URL (`http://localhost:4000/sessions/oidc/lark-main/callback` for local). Lark matches exactly.
- **Login fails for a valid user** — the user is outside the app's availability scope. Add them in the Lark developer console and publish a new version.
- **Directory sync returns empty** — the directory scopes (`contact:*`, `auth:user_access_token:read`) are not granted, or the app version is unpublished. Scopes and publication are the usual culprits.
- **Realtime sync is stale** — the long connection has not established. Confirm the control plane has outbound internet access; keep it running and let the connection come up.

## How this differs from the other IdP guides

- **vs Entra ID** — same four capabilities, but Lark's realtime sync rides the long-connection WebSocket, not Graph subscriptions. No public ingress, no `SubscriptionReconciler`, no `clientState` — simpler to run.
- **vs Google Workspace** — Google Workspace has full sync only, no realtime. Lark has both, via the long connection.
- **vs the chat binding** — the same self-built app does both, with the same `appID`/`appSecret`. The identity face adds the redirect URL and the directory scopes; the chat face adds the message scopes. They are one app, two faces.

## What this guide is not

It is not a Lark developer-console tutorial — the console changes, and the exact scope names are Lark's to document. It is not a way to admit users outside the app's scope; the scope is the boundary, and widening it is a Lark-side decision. And it is not separate from the chat face; one app serves both, and the app's configuration is shared.

## Next steps

- For the adapter reference (both faces), read the [Lark adapter](../adapters-lark/) page.
- For the chat face of the same app, read [Your first Lark bot](../lark-first-bot/).
- For the permission model the synced groups feed into, read [Principal and AuthZ](../principal-authz/).
