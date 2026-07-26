---
title: Admin sign-in with Google Workspace
description: Configure Google Workspace as the admin identity provider — the OAuth client, the workspace boundary, directory sync through a service account, and the enforcement the adapter applies at login.
section: Guides
order: 313
---

This guide federates Console admin sign-in to Google Workspace. By the end, admins sign into Ankole with their Google work account, sign-in is fenced to your workspace domain, and directory groups sync into AuthZ so you can grant authority by group. It builds on the [Google Workspace adapter](../adapters-google-workspace/) reference; this is the operator walkthrough for the identity face.

The decisive property, stated up front: the adapter enforces a workspace boundary at login — `email_verified`, a `hd` claim present, and both the `hd` and the email domain in `allowedDomains`. A Google account from outside your workspace cannot become an Ankole admin, even with a valid token. The boundary is the point; set it deliberately.

## What you need in Google Cloud

Two pieces of Google Cloud configuration, each for a different job:

1. **An OAuth client** for admin sign-in (the OIDC flow). Create it under *APIs & Services → Credentials*. Note its `clientID` and `clientSecret`, and add the Ankole Console's OIDC callback URL to its authorized redirect URIs. Subscribe it to the `openid`, `email`, and `profile` scopes.

2. **A service account** for directory sync, with **domain-wide delegation** to the Google Workspace customer you want to read. Download its JSON key — this is the `serviceAccountKey`. The delegation lets the service account impersonate an admin user (`adminEmail`) to call the Directory API.

These are separate because they do separate things: the OAuth client authenticates the *admin* signing in; the service account reads the *directory* on Ankole's behalf. You can use the identity provider without directory sync (skip the service account), but not the reverse.

## Configure the identity provider

Create the identity provider through the Console:

```bash
curl -X PUT https://ankole.example.com/api/v1/identity-providers/google-workspace \
  -H "Authorization: Bearer $CONSOLE_TOKEN" \
  -H "Content-Type: application/json" \
  -d '{
    "adapter_id": "google-workspace",
    "clientID": "<oauth-client-id>",
    "clientSecret": "<oauth-client-secret>",
    "oidc": { "enabled": true, "allowedDomains": ["example.com"] },
    "serviceAccountKey": "<service-account-json>",
    "adminEmail": "directory-reader@example.com",
    "sync": { "contacts": true }
  }'
```

The fields the adapter validates:

| Field | Required when | Meaning |
|---|---|---|
| `clientID` | `oidc.enabled` is true | the OAuth client id |
| `clientSecret` | `oidc.enabled` is true | the OAuth client secret (encrypted at rest) |
| `oidc.allowedDomains` | `oidc.enabled` is true | the workspace domains permitted to log in |
| `serviceAccountKey` | `sync.contacts` is true (default) | the service account JSON key |
| `adminEmail` | `sync.contacts` is true | the delegated admin the service account impersonates |

Every AppConfigure pattern for this adapter is encrypted — `clientSecret` and `serviceAccountKey` are secret material, stored encrypted by the control plane.

## The workspace boundary at login

When an admin signs in, the adapter runs the OIDC authorization-code flow and then checks three things before accepting the identity:

1. **`email_verified` is true** — Google confirmed the email.
2. **A `hd` (hosted domain) claim is present** — the account belongs to a workspace, not a `gmail.com` consumer account.
3. **Both the `hd` and the email domain are in `allowedDomains`** — the workspace is *yours*.

A failure at any check rejects the login with `login_domain_not_allowed`. This is why `allowedDomains` matters: it is the fence that keeps a valid Google token from outside your workspace out of your Console. Set it to exactly the domains you mean, and add a second domain only if you genuinely run a multi-domain workspace.

## Directory sync into AuthZ

With `sync.contacts` on, the adapter pulls Google Workspace groups and memberships into AuthZ groups, using the service account (impersonating `adminEmail`) to call the Directory API. The customer is resolved as `my_customer` — the service account's own customer — so you do not look up a customer id.

Google Workspace sync is **full sync only** (`directory_full_sync`). There is no realtime subscription: the Google-side channel the other adapters use for realtime does not apply, so the adapter syncs on a cadence instead. Plan for the sync to lag minutes-to-hours behind a directory change, not seconds.

After the first sync, the workspace's groups exist as Ankole AuthZ groups. Assign grants to them through [Principal and AuthZ](../principal-authz/) — "everyone in the `engineering@example.com` group can administer these agents" is now a real grant, sourced from Google Workspace as the source of truth.

## Verify the login

Open the Console sign-in and choose the Google Workspace path. Sign in with a user in an `allowedDomains` domain. A successful login resolves to an Ankole Principal, and the first successful user becomes this installation's root administrator (the activation code expires).

Then verify the fence: a login attempt from a `gmail.com` account, or from a workspace not in `allowedDomains`, should fail with `login_domain_not_allowed`. If it does not, `allowedDomains` is set too permissively — fix it before relying on it.

## When something does not work

- **Login fails at the redirect** — the OAuth client's authorized redirect URIs do not include the Ankole Console callback, or the `clientID` does not match. The error surfaces at Google before Ankole sees a token.
- **`login_domain_not_allowed` for a valid user** — the user's domain is not in `allowedDomains`, or the user is on a `gmail.com` consumer account (no `hd` claim). Add the domain or use a workspace account.
- **Directory sync returns empty** — the service account lacks domain-wide delegation, or `adminEmail` is not a delegated admin. Confirm delegation in Google Cloud for the Directory API scopes, and that `adminEmail` is lowercased and contains `@`.
- **Sync is stale** — full sync runs on a cadence, not realtime. A group change in Google Workspace appears after the next sync, not immediately.

## What this guide is not

It is not a Google Cloud setup tutorial — the OAuth client and service account are standard Google configuration, and Google's console changes. It is also not a way to admit consumer Google accounts; the `hd` enforcement is deliberate, and removing it is not a supported configuration. The adapter exists to federate a *workspace*, and the boundary is the feature.

## Next steps

- For the adapter reference, read [Google Workspace adapter](../adapters-google-workspace/).
- For the permission model the synced groups feed into, read [Principal and AuthZ](../principal-authz/).
- For the identity-provider routes, read the [Console API reference](../console-api/).
