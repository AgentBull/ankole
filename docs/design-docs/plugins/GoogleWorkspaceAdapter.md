# Google Workspace Adapter

The Google Workspace Adapter lets people sign in with Google and imports users
and groups. It does not handle chat. The control plane keeps all Google
credentials and makes every Google API call.

Read [Plugins](../Plugins.md) for the common Plugin rules. Read
[Principal](../Principal.md) for rules that link the same human across providers.

## Current IDs and Features

| Item | Current value |
| --- | --- |
| Plugin ID | `google-workspace-adapter` |
| API version | `1` |
| Plugin declaration | `principals.identity_provider` |
| Adapter ID | `google-workspace` |
| Configuration key | `principals.identity_providers.google-workspace.<id>` |
| Provider library | `libs/google_openapi` |

The adapter declares these capabilities:

- `oidc_authorization`
- `oidc_code_exchange`
- `directory_full_sync`

The adapter does not declare `directory_realtime_sync`. Later full syncs pick
up directory changes. The Plugin runs no long-lived connection.

## Settings

`Ankole.Plugins.GoogleWorkspaceAdapter.Config` checks the settings.
AppConfigure encrypts the fields marked as secrets.

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

`oidc.allowedDomains` must contain at least one domain when the operator enables login.
Directory sync requires `serviceAccountKey` and `adminEmail`.

## Sign In with Google

The control plane exchanges the authorization code and then reads Google's
OpenID user information endpoint. It does not parse the ID token itself.

The login gate requires a verified email and a present `hd` claim. Both the
email domain and the `hd` claim must match `oidc.allowedDomains`. The `hd`
authorization parameter is only an account selection hint.

The Google `sub` claim becomes the external subject ID. Directory sync uses
the Google Directory user ID. Current Google accounts use the same stable ID
on both paths.

## Import Users and Groups

Full sync reads groups before users. It creates one AuthZ group for each Google
group. It imports direct `USER` members but does not expand nested groups.

For each user, it stores:

- Google user ID as the external subject ID
- Primary email
- Display name
- First organization job title
- First mobile telephone number
- Organization unit path as provider metadata

Full sync skips suspended and archived users by default. Organization units do
not become AuthZ groups. The adapter does not fetch avatars.

Matching email can link Google and Slack accounts to one Principal. A conflict
does not move an existing account. An operator must merge an existing duplicate.

## Restart and Recovery

Principals and AuthZ store imported users, groups, and memberships. The provider
library caches access tokens in memory and requests a new token after restart.

Run a full sync when Google and Ankole might differ. The adapter has no Google
webhook or watch channel.

## Tests

The automated tests cover provider HTTP behavior, login checks, configuration,
directory imports, and account links based on email. The repository does not
contain credentials for a real Google Workspace acceptance test.

The implementation sources are:

- `plugins/google_workspace_adapter/lib/ankole/plugins/google_workspace_adapter.ex`
- `plugins/google_workspace_adapter/lib/ankole/plugins/google_workspace_adapter/`
- `libs/google_openapi/`
