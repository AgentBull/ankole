---
title: Identity providers
description: How identity providers work across all five supported platforms — the shared OIDC model, the directory-sync capabilities, and which adapter serves which platform.
section: User guide
order: 44
---

An identity provider (IdP) is how admins sign into the Ankole Console and how directory groups sync into AuthZ. Five platforms are supported as identity providers, each through its adapter's identity face. This page is the consolidated operator view across all five — the shared model, the differences, and where to go for each platform's step-by-step guide.

The decisive property, stated up front: every identity provider uses **OIDC for sign-in and directory sync for AuthZ groups**, but the boundary that fences sign-in is different per platform. Lark and DingTalk fence by the app's availability scope or `corpid`; Slack by the workspace (`teamID`); Entra ID by the tenant; Google Workspace by `allowedDomains`. The boundary is always there; it is just expressed differently.

## The five supported providers

| Provider | Adapter id | Sign-in boundary | Directory sync | Realtime |
|---|---|---|---|---|
| **Lark / Feishu** | `lark` | app availability scope | IM groups + org structure | yes (long-connection WebSocket) |
| **DingTalk** | `dingtalk` | `corpid` (organization) | org structure (departments + users) | yes (Stream WebSocket) |
| **Slack** | `slack` | workspace (`teamID`, optional) | workspace membership | yes (Socket Mode) |
| **Entra ID** | `entra-id` | tenant (single-tenant app) | directory groups + users | yes (Graph subscriptions) |
| **Google Workspace** | `google-workspace` | `allowedDomains` (workspace domains) | directory groups | no (full sync only) |

Every provider carries `oidc_authorization` and `oidc_code_exchange` for sign-in, and `directory_full_sync` for periodic sync. Four of the five also carry `directory_realtime_sync`; Google Workspace does not, because the Google-side channel the others use does not apply.

## The shared model

Regardless of platform, the flow is the same:

1. **Configure the identity provider** through the Console or setup flow, with the platform's credentials.
2. **Admin signs in** through the Console's OIDC path. The adapter runs the authorization-code flow, reads the user's identity, and resolves it to an Ankole Principal. The first successful user becomes root administrator; the activation code expires.
3. **Directory sync runs** — full sync on a cadence, realtime (where supported) through the platform's event channel. Groups and memberships arrive as Ankole AuthZ groups.
4. **Operator assigns grants** to the synced groups through [Principal and AuthZ](../principal-authz/).

The adapter owns the OIDC and directory specifics; Ankole owns the Principal resolution and the AuthZ grants. The boundary between them is the synced group — the adapter provides the membership, AuthZ decides what it means.

## Directory sync: full and realtime

Two shapes, where the platform supports both:

- **Full sync** reads the directory through the platform's API on a cadence. It is the floor — it converges Ankole's view to the platform's truth even if realtime misses a change. The cadence is controlled by `principals.identity_providers.directory_full_sync_interval_hours` (AppConfigure).
- **Realtime sync** uses the platform's event channel — the long-connection WebSocket (Lark), the Stream API (DingTalk), Socket Mode (Slack), or Graph subscriptions (Entra ID). A directory change reaches Ankole within minutes, not on the next full sync.

Google Workspace is full-sync only. The other four support both, with realtime riding the same connection the chat face uses (or, for Entra ID, Graph subscriptions managed by a `SubscriptionReconciler`).

## What to configure

The common steps across all providers:

1. **Register an app** on the platform's developer console — the same app the chat binding uses, for Lark/DingTalk/Slack; a separate app registration for Entra ID; an OAuth client plus service account for Google Workspace.
2. **Add the OIDC redirect URL** to the app's security settings — the Ankole Console callback.
3. **Grant directory scopes** — the permissions the adapter needs to read users, groups, and departments.
4. **Configure the identity provider** through `PUT /identity-providers/<provider_id>` with the platform's `adapter_id` and credentials.

Each platform's step-by-step guide is linked below.

## When something does not work

The common failures, across all providers:

- **Login fails at the redirect** — the redirect URL does not match, or the credentials are wrong. Fix the app's redirect configuration before anything else.
- **Login fails for a valid user** — the user is outside the boundary (wrong workspace, wrong tenant, wrong domain, outside app scope). The boundary is the platform-specific fence; widen it on the platform side, not in Ankole.
- **Directory sync returns empty** — directory scopes not granted, or the app version is unpublished. Scopes and publication are the usual culprits.
- **Realtime sync is stale** — the event channel is not connected. Confirm the connection type (long-connection, Stream, Socket Mode, Graph subscription) is healthy.

## The per-platform guides

| Platform | Guide |
|---|---|
| Lark / Feishu | [Admin sign-in with Lark](../lark-admin-login/) |
| DingTalk | [Admin sign-in with DingTalk](../dingtalk-admin-login/) |
| Slack | [Admin sign-in with Slack](../slack-admin-login/) |
| Entra ID | [Admin sign-in with Entra ID](../entra-id-admin-login/) |
| Google Workspace | [Admin sign-in with Google Workspace](../google-workspace-admin-login/) |

## What this guide is not

It is not a per-platform configuration tutorial — each platform has its own guide linked above. It is not a security-hardening guide — see [Security hardening](../security-hardening/) for the boundary and rotation discipline. And it is not a substitute for the AuthZ page — the identity provider provides the groups; AuthZ decides what they can do.

## Next steps

- For the permission model synced groups feed into, read [Principal and AuthZ](../principal-authz/).
- For the Console routes, read the [Console API reference](../console-api/).
- For your platform's step-by-step, follow the table above.
