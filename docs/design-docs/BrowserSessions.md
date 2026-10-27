# Browser Sessions

Ankole stores independent browser authentications in PostgreSQL. An active
selection supplies the default for a new page. Each open Pod page keeps its own
authentication and tenant. A change to the default cannot change that page's
identity.

## Ownership and records

The `Ankole.BrowserSessions` Ash domain owns browser groups, outbound upstream
OIDC ceremony states (`OidcState`), independent authentications, and tenant
access proofs. `Ankole.OIDC` owns inbound OIDC authorization requests
(`AuthorizationRequest`) and RP links. `AnkoleWeb.Session` owns sealed browser
cookies, short-lived sealed ceremony tickets, and request selection.

A group has an ID, revision, logout revision, default authentication and tenant,
and expiry. An authentication records its source, subject, tenant when scoped,
authentication time, challenge start time, authentication methods (`amr`),
verified email or phone, local `authenticated_at`, expiry, CSRF secret, and Console admission flag.
`PodAuthentication` binds a proved authentication to one Human and access version.
`OidcState` records an outbound upstream OIDC redirect's state token, browser
group, target tenant, provider ID, purpose, mode, started revision, redirect
URI, return path, prompt, optional invitation or reauthentication pin, optional
OIDC authorization request ID, consumption state, and expiry.

Top-level operations own a `Repo.transact_top_level/2` transaction. Their
`*_in_tx` functions run in the caller's transaction. The browser row lock comes
before authentication, proof, and ceremony changes. Each ceremony resource owns
its single-use consumption transition; a consumed state or authorization request
cannot reopen.

An authentication lives for 24 hours; an outbound OIDC state and an inbound OIDC
authorization request each live for 10 minutes. Completion extends the group's
expiry to cover its proof. Cleanup preserves a group while a valid proof
references it. [Authentication](Authentication.md) owns code challenges,
delivery, and rate windows.

## Login purposes and targets

`GET /sessions/new` serves the login shell directly without creating a database
record. The shell reads its target from the host and query parameters
(`purpose=console`, `return_to`, `switch=1`, `prompt=login`, `invitation_token`,
sealed `reauth`, sealed `invitation`, or `oauth_request`).

`pod`, `console`, and `oauth` logins target one tenant. Pod entry uses its host
or explicit target. Console uses the privileged tenant and requires site
administration membership. OAuth uses the Client's tenant recorded on
`AuthorizationRequest`. Outbound enterprise SSO creates an `OidcState` row when
the browser visits `/sessions/oidc/:provider_id/authorization`, and its callback
completes against that recorded tenant and provider. A `site` login verifies a
personal credential and selects its available Pods.

The site proof's `console_authenticated` flag is set through a successful Console
login. Console requests also check the privileged tenant, current Human access,
and `siteadmin`. Pod proofs have independent scope and access versions.

Pod login and additional credential flows use additive authentication mode. A
trusted server entry sets this mode. Each open HTML document pins its
authentication reference and Pod ID.

`GET /api/v2/browser/session` returns activated Pod identities, pending Pods,
and proved site authentications. A zero-Pod site proof is a valid session.
`POST /api/v2/browser/authentications/current` accepts `authenticationRef` and
`tenantID`. It checks the proof, current policy, and any pending claim before it
changes the browser default. The selected document navigates to the target Pod;
other open documents keep their pinned context.

Setup authority is separate from normal authentication.

## Cookies and request selection

The sealed aggregate cookie carries a browser group reference and isolated setup
state. The group reference grants no authenticated access and cannot list or
exchange other accounts' proofs. HTTPS builds use `__Secure-ankole` for this
cookie; HTTP development uses `_ankole_key`. Both use the site's configured
parent domain.

Browser-wide logout retains this unprivileged group reference. A later login
uses the same group. Successful login renews the cookie's expiry so that the
group cookie does not expire before the new authentication. A delayed login
response still names the same group; it cannot displace the next account.

Each authentication has its own sealed cookie, named
`__Secure-ankole-auth-<id>` in HTTPS builds and `_ankole-auth-<id>` in HTTP
development. It carries the authentication ID and revision. Cookies use the
`SessionCookieStore` AEAD format, HttpOnly, the site's configured
parent domain, and `Path=/`; production also requires Secure. Development uses
`ankole.localhost` to permit sharing across Pod subdomains. Login replaces only its own proof
cookie. No response serializes a snapshot of all logged-in accounts.

In development, Vite permits module requests from `http://ankole.localhost:4000`
and its single-label Pod hosts in both editions. These origins must match the
browser hosts that Phoenix serves, so that the login application can load.

`authentication_ref` encodes an ID and revision. It selects a proof; it is not
a credential. The web boundary requires the matching valid cookie and server
record, in the same browser group. A group ID or a known reference alone grants
nothing. An explicit stale or unknown API reference fails without fallback.
Normal requests validate only the cookie for the selected authentication ID.
Only an identity chooser reads all authentication cookies. Stream frames keep
the selected proof and check its current server state each time.

The shell emits `ankole-authentication` and `ankole-pod` metadata. Browser API
requests send `x-ankole-authentication` and `x-ankole-pod`. EventSource, file
subresources, and sandboxed Applet frames cannot send these headers, so Pod
conversation event URLs and `GET /api/v2/pod/pages/:id/files/content` carry the
same references in their query, and
`GET /pod/applet-frame/:authentication_ref/:id/:revision/*path` carries the
authentication reference in its path. These requests still require the selected
proof cookie and browser group, so an open document keeps its identity when
another account becomes active. Other API, navigation, and OIDC authorization
URLs cannot select another logged-in account by adding an identity parameter.
Shareable links contain only the tenant and resource.

Pod API gates check the selected tenant, authentication, current Human access,
and binding. Conversation operations check participant membership or, for a
Page-anchored thread, `page_view` on its anchor Page. A Console
API requires current siteadmin membership; Pod login does not grant access to
v2 management operations or native Console file transfers. Protected responses cannot enter a shared cache.
Pod query keys include both identity and tenant. Console data selection is local
to the document's authentication. Switching the browser default does not change
an open document or cause a failed request to retry as another person.
Navigation within a Pod document to `/me` or `/settings` keeps that document's
authentication and tenant.

Authenticated shells and authenticated APIs use the selected authentication's
CSRF secret. Ceremony shells (`/sessions/new`, `/setup`, `/join/:token`,
`/oauth/logout`) use the sealed browser session cookie's CSRF state, so starting
or repeating a login ceremony does not modify another tab's authentication CSRF
secret. Ceremony API endpoints accept the session CSRF token or, when called
from an authenticated shell, the selected authentication's CSRF token.
BrowserCSRF loads the selected state for the request, verifies both token
validity and an exact matching Origin when supplied, and clears process-local
token state after the response. SameSite does not establish that two Pod origins
trust each other.

## Concurrent completion and revocation

Login completion, single exit, and global exit lock the browser row. Each
mutation advances `browser.revision`. A new or revoked target authentication
gets that revision. Reverification of a live authentication preserves its
reference and CSRF state, so pinned tabs and online RP sessions remain usable.
Console admission is preserved when another ceremony uses the same site proof.
Global exit also writes `logout_revision`. Selection alone does not advance
either counter.

An outbound `OidcState` or inbound `AuthorizationRequest` can complete only when:

```text
ceremony is unconsumed and unexpired
ceremony.started_revision >= browser.logout_revision
target does not exist, or target.revision <= ceremony.started_revision
```

Ordinary email OTP verification establishes a new authentication. The challenge
does not bind that login to a browser revision from code delivery. A valid
unused ordinary code can complete after an earlier authentication ends.
See [Authentication](Authentication.md#verification-ceremonies) for the code's
lifetime, replacement rules, and current policy checks.

The target key is browser, provider, subject, purpose, and tenant. A site source
uses purpose `site` and no tenant, including when an OAuth request invokes
it. A native source uses its tenant, provider, and Principal UID. The provider's
verified external ID is retained separately.

An authentication selected for OAuth reauthentication fixes its expected
authentication ID on `AuthorizationRequest`. Personal settings start
reauthentication through `/api/v2/pod/me/reauthentication`, which seals a
10-minute `browser.reauth` ticket bound to the browser ID, tenant ID, Human UID,
authentication ID, and `started_revision`. Another permitted login source can
complete that operation only if it resolves to the same Human. Neither path can
overwrite a target changed after `started_revision`. Single exit advances the
revoked authentication's revision and writes a revocation tombstone, so any
in-flight OIDC ceremony or reauthentication pinned to that authentication or
target is rejected at completion.

For its session-bound OIDC interactions, Logto's
[email verification routes](https://github.com/logto-io/logto/blob/2c9fde42fdea88f43a802e35c9d47d14afaefa39/packages/core/src/routes/experience/index.ts#L60-L69)
load interaction details before verification. Its pinned OIDC provider
[rejects an interaction whose bound session was destroyed](https://github.com/logto-io/node-oidc-provider/blob/513c523c0e68ee6112da8c871cce86204a136163/lib/provider.js#L445-L452).
This check validates the login context; code expiry and consumption are separate.

| Interleaving | Result |
| --- | --- |
| A and B start OIDC ceremonies at revision 10; B completes at 11 in add mode. | A can complete if A's own target did not change. |
| Two A OIDC ceremonies start at 10; one completes at 11. | The other fails. |
| A exits before its old callback returns. | The retained revocation record rejects that callback; B remains valid. |
| Global exit precedes an old callback. | `logout_revision` rejects it. |
| An ordinary code is sent before logout and submitted afterward. | The valid unused code establishes a new authentication. |
| A late HTTP response writes an old A cookie. | Only A's proof becomes unusable; B's differently named cookie remains valid. |

Revocation records remain until the group can be removed. They cannot disappear
while an old OIDC ceremony could mistake the target for a new subject. OIDC
completion, evidence writes, and state consumption commit together. OAuth
completion binds the verified authentication to one `AuthorizationRequest`, which
`/oauth/authorize/resume` consumes once for code issuance.

Provider network requests run outside the browser lock. Completion rechecks
current state. Use the order browser, then Principal, then RP associations.
Site authentication locks verified Humans in stable UID order.

The server cannot order HTTP responses at the browser. After a late response
replaces A's cookie with an obsolete revision, A must sign in again. This
recovery cannot invalidate another authentication.

## Site sources and Human recovery

`IdentityProviders.SiteSources` verifies a source's proof and returns its
subject, actual authentication time, ceremony start, verified contacts, and
methods. Email OTP uses a consumed durable challenge. The source identifier
addresses personal credential bindings across tenants.

Every Pod proof requires an active Human, an available tenant, a current
credential binding and access version, and the current Pod login policy.
Unavailable membership in one Pod leaves other independently valid Pods usable.

A fresh target-Pod login can claim a unique pending Human. The public chooser
and Pod switcher can also claim a pending member or directed invitation.
The ceremony start must be later than the last release of a recyclable
identifier. An older proof requires another verification.

`create_pod_access/2` locks the site authentication while its callback creates
the tenant, Human, credential, and administrator membership in one transaction.
Invitation acceptance locks its quota and records tenant access in that same
transaction. Enterprise SSO completes only its fixed tenant's proof.

Restoration requires fresh verification at the restored Human access version.
Switching checks evidence; it cannot refresh that evidence.

## Freshness and logout

Email OTP verification establishes a new authentication event. A provider
adapter must supply evidence for requested freshness. Ordinary Lark login has
no such evidence and omits `auth_time`; it cannot satisfy `prompt=login`,
`max_age`, or essential `auth_time`. A profile read or callback time is not a
new authentication. Reuse and selection preserve the event's actual time.

Personal credential changes and voluntary Pod exit use `authenticated_at`, the
local completion time of browser verification. This verification expires 15
minutes after that timestamp. `challenge_started_at` is the ceremony start used to reject
proofs from before a recycled identifier was released. Personal settings
reauthentication requires a new verification ceremony and cannot reuse a stored
proof. The provider's `auth_time` remains its actual authentication event time.
OIDC `prompt=login` and `max_age` keep their provider evidence requirements.

Single exit revokes one authentication and its online RP associations. Its
other Pod proofs fail with the parent. Other authentications remain usable.
If it was active, the default is cleared; another account is not selected.
A Pod stream rechecks its original proof before each frame or ping.

Console logout and confirmed RP logout apply browser-wide. They advance
`logout_revision` and end all authentications and online RP associations in one
transaction. They cancel pending OIDC states and authorization requests.
Reauthentication tied to a revoked proof also fails. The response drops the
individual proof cookies after commit and keeps the group reference.
A stale RP logout confirmation cannot end a newer browser revision. A
late response cannot restore a revoked proof. RP confirmation commits this
revocation once. Back-channel delivery and cookie cleanup do not repeat it or
end an authentication added after that commit.

Browser exit does not disable a Human, end another browser, or log out an
upstream provider. Granted `offline_access` tokens keep their OIDC lifetime;
Human disablement revokes them. See [OIDC Server](OIDCServer.md).

## Expiration and cleanup

The hourly OIDC cleanup uses one cutoff across all tenants. Tenant cleanup
removes expired inbound `AuthorizationRequest` rows; afterward, the job calls
`BrowserSessions.cleanup_expired/1` once, including when a tenant failed.
Browser Sessions removes expired `OidcState` rows and expired groups with no
retained RP association. Foreign keys then remove their independent
authentications and proofs. Tenant deletion removes its access proofs, outbound
OIDC states, inbound OIDC authorization requests, and native authentication rows
through the tenant deletion owner.

The configured `RequestHost` policy declares host classification, the shared
cookie domain, tenant origins, canonical origins, and explicit per-host route
admission; a route declaration alone does not grant access from a Pod Host.
