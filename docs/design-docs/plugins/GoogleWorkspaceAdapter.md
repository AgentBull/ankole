# Google Workspace Adapter

The Google Workspace Adapter provides Google OIDC sign-in and full directory
synchronization for users and groups; it does not handle messaging. All Google
credentials stay on the control plane, which executes every Google API call
directly.

See [Plugins](../Plugins.md) for shared Plugin rules and
[Principal](../Principal.md) for cross-provider identity linking.

## Current IDs and Features

| Item | Current value |
| --- | --- |
| Plugin ID | `google-workspace-adapter` |
| API version | `1` |
| Plugin declaration | `principals.identity_provider` |
| Adapter ID | `google-workspace` |
| Configuration key | `principals.identity_providers.google-workspace.<id>` |
| Provider library | `plugins/google_workspace_adapter/lib/google_openapi` |

Declared capabilities are `oidc_authorization`, `oidc_code_exchange`, and
`directory_full_sync`. Because the adapter does not declare
`directory_realtime_sync` or open long-lived connections, subsequent full sync
runs pick up directory changes.

## Settings

`Ankole.Plugins.GoogleWorkspaceAdapter.Config` validates provider settings, and
`AppConfigure` encrypts all secret fields at rest:

| Field | Purpose |
| --- | --- |
| `clientID`, `clientSecret` | Google OAuth client credentials |
| `oidc.enabled` | Enables Google login |
| `oidc.scopes` | Sets login scopes |
| `oidc.allowedDomains` | Limits login to listed Workspace domains |
| `serviceAccountKey` | Provides the delegated service account JSON key |
| `adminEmail` | Selects the administrator for delegation |
| `sync.contacts` | Enables full directory sync |
| `sync.pageSize` | Sets the Directory API page size |
| `sync.includeSuspended` | Includes suspended and archived users |

Enabling OIDC login requires at least one domain in `oidc.allowedDomains`, and
enabling directory sync requires both `serviceAccountKey` and `adminEmail`.

## Sign In with Google

During OIDC sign-in, the control plane exchanges the authorization code and
fetches the user's claims from Google's OpenID UserInfo endpoint rather than
parsing the JWT ID token locally.

To pass the sign-in gate, the UserInfo response must carry a verified email
address and a present `hd` (hosted domain) claim, and both the email domain and
`hd` must match `oidc.allowedDomains` (the outbound `hd` authorization query
parameter acts only as a Google account-picker hint). Both OIDC sign-in
(`sub`) and Google Directory sync (Directory user ID) resolve to the same stable
numeric Google account identifier.

## Import Users and Groups

Full directory sync imports Google groups before importing users, creating one
`AuthZ` group per Google group and syncing direct `USER` members without
flattening nested groups (Google organizational units are stored only as
provider metadata rather than becoming `AuthZ` groups).

For each user—skipping suspended and archived accounts unless
`sync.includeSuspended` is enabled, and never fetching avatars—the sync records:

- the Google user ID as the external subject ID
- the primary email address
- the display name
- the first organization job title
- the first mobile phone number
- the organizational unit path in provider metadata

Matching verified email addresses can link a person's Google Workspace and Slack
identities onto a single Principal; if a conflict occurs with an existing
account, sync leaves existing Principals untouched so an operator can review and
merge duplicates explicitly.

## Restart and Recovery

Imported Principals, groups, and memberships persist in PostgreSQL under
`Principals` and `AuthZ`, while `google_openapi` caches short-lived access
tokens in memory and mints fresh tokens automatically after a restart. Because
the adapter registers no Google push watch channels or webhooks, operators run a
full sync whenever Ankole and Google Workspace may have drifted.

## Tests

Automated tests cover `google_openapi` HTTP behavior, OIDC domain/verification
gates, configuration validation, user/group imports, and email-based Principal
linking; live Google Workspace acceptance testing requires operator credentials
outside the repository.

Implementation paths:

- `plugins/google_workspace_adapter/lib/ankole/plugins/google_workspace_adapter.ex`
- `plugins/google_workspace_adapter/lib/ankole/plugins/google_workspace_adapter/`
- `plugins/google_workspace_adapter/lib/google_openapi/`
