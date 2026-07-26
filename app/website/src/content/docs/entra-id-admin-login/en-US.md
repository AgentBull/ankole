---
title: Admin sign-in with Entra ID
description: Configure Entra ID (Azure AD) as the admin identity provider — the app registration, directory full and realtime sync through Graph subscriptions, and the reconciler that keeps them alive.
section: Guides
order: 318
---

This guide federates Console admin sign-in to Entra ID (Azure AD). By the end, admins sign into Ankole with their Microsoft work account, directory groups sync into AuthZ — full sync on a cadence, realtime through Graph subscriptions — and the subscriptions stay alive without babysitting. It mirrors [Admin sign-in with Google Workspace](../google-workspace-admin-login/); the differences are Entra-specific: tenant-scoped app registration, Graph subscription lifecycle, and realtime sync the Google Workspace adapter does not have.

The decisive property, stated up front: the Entra ID identity face carries **both** `directory_full_sync` and `directory_realtime_sync`. Realtime sync runs through Graph subscriptions that the adapter creates, renews inside a 48-hour window, and re-creates if dropped — so a directory change in Entra ID reaches Ankole within minutes, not on the next full sync. This is the capability the Google Workspace adapter lacks, and the reason the two adapters are not interchangeable.

## What you need in Entra ID

One app registration does both jobs (OIDC sign-in and directory access), unlike Google Workspace's two-piece OAuth-client-plus-service-account:

| Field | What it is |
|---|---|
| `tenantID` | the Entra ID tenant id — a GUID |
| `clientID` | the app registration's application (client) id |
| `clientSecret` | the app's client secret |

Register the app in the Entra ID portal, single-tenant by default. Add the Ankole Console's OIDC callback to its redirect URIs. Grant the Microsoft Graph permissions it needs — `User.Read` and `openid`/`profile`/`email` for sign-in, and the directory read permissions (`Group.Read.All`, `User.Read.All`) for sync — and grant admin consent. The `clientSecret` is the same secret you would use for the Teams chat face, but the identity face uses `clientID`/`clientSecret`/`tenantID`, not the chat face's `appID`/`appPassword`/`botTenancy`.

## Configure the identity provider

```bash
curl -X PUT https://ankole.example.com/api/v1/identity-providers/entra-main \
  -H "Authorization: Bearer $CONSOLE_TOKEN" \
  -H "Content-Type: application/json" \
  -d '{
    "adapter_id": "entra-id",
    "tenantID": "<tenant-guid>",
    "clientID": "<client-id>",
    "clientSecret": "<client-secret>",
    "sync": { "contacts": true, "realtime": true, "pageSize": 999 }
  }'
```

The fields the adapter validates:

| Field | Required when | Meaning |
|---|---|---|
| `tenantID` | always | the Entra ID tenant (GUID) |
| `clientID` | always | the app registration's client id |
| `clientSecret` | always | the app's secret (encrypted at rest) |
| `sync.contacts` | default true | whether directory sync runs at all |
| `sync.realtime` | default true | whether Graph subscriptions are used |
| `sync.pageSize` | default 999 | the Graph page size (1–999) |

The adapter id is `entra-id` (the same M365 plugin declares it alongside the `teams` chat adapter and two webhook handlers). Every pattern is encrypted; `clientSecret` is secret material.

## The login flow

Admin sign-in is standard Entra ID OIDC: redirect to Microsoft, exchange the code, read the user. The adapter resolves the user to an Ankole Principal; the first successful user becomes this installation's root administrator and the activation code expires. Unlike the Google Workspace adapter, there is no `allowedDomains` boundary to configure — the tenant itself is the boundary. A user from another tenant cannot authenticate against a single-tenant app registration, so the app's tenant scoping is what fences sign-in.

## Directory full sync

With `sync.contacts` on, the adapter reads the directory through Graph on a cadence, paging at `sync.pageSize` rows at a time. Full sync is the floor: it guarantees Ankole's view of the directory converges to Entra ID's truth even if realtime misses a change. After a full sync, Entra ID groups exist as Ankole AuthZ groups, and you assign grants to them through [Principal and AuthZ](../principal-authz/).

## Directory realtime sync (Graph subscriptions)

This is the capability that sets the Entra ID adapter apart. With `sync.realtime` on, the adapter creates Graph subscriptions for the directory resources, each carrying a `clientState` secret. When something changes in Entra ID, Graph POSTs a notification to the adapter's `entra-id` directory webhook handler (kinds `["directory"]`), authenticated by the matching `clientState` — a notification without the right `clientState` is rejected.

The `SubscriptionReconciler` keeps the subscriptions alive:

- it runs at boot, every 6 hours by default, and on the save-time reconcile hook when you save the identity provider;
- it renews subscriptions inside a **48-hour renewal window** before they expire;
- it re-creates subscriptions that dropped;
- the interval (6 hours) sits far inside the 48-hour window, so several missed runs cost nothing.

Turn `sync.realtime` off and the reconciler deletes the subscriptions instead — full sync becomes the only path, with its cadence lag.

## Verify the login and the sync

Open the Console sign-in and choose the Entra ID path. Sign in with a user in the tenant. A successful login resolves to an Ankole Principal.

Then verify the sync:

- **Full sync** — after the first sync run, check `/principal-groups` for the Entra ID groups.
- **Realtime sync** — change a group membership in Entra ID and watch `/principal-groups` update within minutes. If it does not, the subscription may have dropped; the reconciler will re-create it within its interval, but check that Graph can reach your public webhook (the directory webhook needs the same public ingress the Teams chat face does).

## When something does not work

- **Login fails at the redirect** — the app registration's redirect URIs do not include the Ankole Console callback, or `clientID`/`tenantID` do not match. The error surfaces at Microsoft before Ankole sees a token.
- **Login fails for the right user** — the app is single-tenant and the user is in another tenant, or admin consent was not granted for the Graph scopes.
- **Full sync returns empty** — the app lacks `Group.Read.All`/`User.Read.All`, or admin consent was not granted. Consent is the usual culprit, not the page size.
- **Realtime sync is stale** — Graph cannot reach the public webhook (ingress down, certificate expired), or the subscription dropped and the reconciler has not re-created it yet. Full sync will still converge eventually.

## What this guide is not

It is not an Entra ID app-registration tutorial — the portal changes, and the scopes are Microsoft's to document. It is not a way to admit personal Microsoft accounts; the tenant is the boundary, and a single-tenant app keeps it that way. And it is not interchangeable with the Google Workspace adapter; the Entra ID face has realtime sync through Graph subscriptions, the Google Workspace face does not, and that difference is why they are separate adapters.

## Next steps

- For the adapter reference (all four contracts), read the [Microsoft 365 adapter](../adapters-microsoft-365/) page.
- For the permission model the synced groups feed into, read [Principal and AuthZ](../principal-authz/).
- For the public-ingress requirement realtime sync shares with Teams chat, read [Your first Microsoft Teams bot](../m365-teams-bot/).
