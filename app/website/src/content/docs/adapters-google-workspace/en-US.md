---
title: Google Workspace adapter
description: Connect Ankole admin sign-in to Google Workspace — OIDC login and directory sync through a service account, with every secret encrypted at rest.
section: User guide
order: 19
---

The Google Workspace adapter is the identity-focused adapter of the set. It signs admins into the Console with their Google work account, and it pulls Google Workspace groups into AuthZ. It is not a chat adapter — there is no message routing here.

## What the adapter declares

`Ankole.Plugins.GoogleWorkspaceAdapter` (plugin_id `"google-workspace-adapter"`) registers one contract:

- an **identity** declaration under `principals.identity_provider`, adapter id `"google-workspace"`.

There is no chat face. The adapter owns two capabilities on that one contract: OIDC login (`oidc_authorization`, `oidc_code_exchange`) and full directory sync (`directory_full_sync`). The single AppConfigure pattern, `principals.identity_providers.google-workspace.*`, is encrypted — the OAuth client secret and the service-account key are secret material, and the control plane stores them encrypted.

## Prerequisites

You need two pieces of Google Cloud configuration:

1. **An OAuth client** for OIDC login. The client gives you the `clientID` and `clientSecret` the OIDC config requires. Add the Ankole Console OIDC callback to the client's authorized redirect URIs.
2. **A service account** for directory sync, with domain-wide delegation to the Workspace customer you want to read. The service-account key (`serviceAccountKey`) is the JSON key file Google generates; `adminEmail` is the Workspace administrator the service account impersonates through that delegation.

Give the OAuth client the scopes the adapter requests on login — `openid`, `email`, `profile` — and grant the service account domain-wide delegation for the Directory API read scope.

## Configure Google Workspace as the identity provider

```bash
curl -X PUT https://ankole.example.com/api/v1/identity-providers/google-workspace \
  -H "Authorization: Bearer $CONSOLE_TOKEN" \
  -H "Content-Type: application/json" \
  -d '{
    "adapter_id": "google-workspace",
    "clientID": "...",
    "clientSecret": "...",
    "oidc": { "enabled": true, "scopes": ["openid", "email", "profile"], "allowedDomains": ["example.com"] },
    "serviceAccountKey": "...",
    "adminEmail": "admin@example.com",
    "sync": { "contacts": true }
  }'
```

The adapter validates the config on save. `clientID` and `clientSecret` are required when `oidc.enabled` is true. `serviceAccountKey` and `adminEmail` are required when `sync.contacts` is true: the key must be a parseable service-account JSON, and `adminEmail` must contain `@` (it is stored lowercased). `oidc.allowedDomains` is required for OIDC — Google has no tenant isolation, so the adapter restricts login to the Workspace domains you list.

## OIDC login

When an admin signs in, the adapter runs the OIDC authorization-code flow against Google: it sends the browser to Google's authorization endpoint, exchanges the returned code for tokens at Google's token endpoint, and reads the user's identity from userinfo. A successful login resolves to one Ankole Principal.

The `clientID` the adapter sends must match the OAuth client you configured. The adapter also enforces the workspace boundary on the returned claims: the email must be verified, the hosted-domain (`hd`) claim must be present, and both the `hd` and the email domain must be in `allowedDomains`. A personal Gmail address, or an account from a domain you did not list, is rejected.

## Directory sync

Directory sync pulls Google Workspace groups and their direct USER members into AuthZ groups, so an admin's group memberships in Google Workspace become their AuthZ group memberships in Ankole. The adapter uses the service account, impersonating `adminEmail` through domain-wide delegation, to obtain a short-lived access token for the Directory API; it reads the customer as `my_customer`, which resolves to the delegated admin's Workspace customer.

Service-account access tokens are short-lived, so the adapter signs a fresh assertion for each call, and sync runs on a periodic full-sync cycle (there is no realtime push from Google in this phase). Nested groups are not expanded — only direct USER members are projected. After sync, assign grants to the synced groups through the [Principal and AuthZ](../principal-authz/) surface.

## When something does not work

- **Login fails at the redirect** — confirm the OAuth client's authorized redirect URIs include the Console OIDC callback, and that the `clientID` the adapter sends matches the client.
- **Login is rejected after returning from Google** — the email must be verified, and both the `hd` claim and the email domain must be in `allowedDomains`. A non-Workspace account, or one from a domain you did not list, fails here.
- **Directory sync returns empty** — confirm the service account has domain-wide delegation for the Directory API read scope, that `adminEmail` belongs to the Workspace customer you mean (`my_customer` follows the delegated admin), and that `sync.contacts` is on.
- **Tokens expire mid-sync** — service-account access tokens are short-lived; the adapter signs a fresh assertion each call. If sync fails on auth every cycle, check that the `serviceAccountKey` is still valid in Google Cloud.

## Next steps

- For the identity-provider and sync routes, read the [Console API reference](../console-api/).
- For how synced groups become authority, read [Principal and AuthZ](../principal-authz/).
