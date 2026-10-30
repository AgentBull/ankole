# Browser Sessions

Ankole stores independent browser authentications in PostgreSQL. While an active
selection supplies the default identity for newly opened pages, each open Pod
page pins its own authentication and tenant, so changing the browser default
never alters an already open page's identity.

## Ownership and records

Three modules divide browser session responsibilities:

- `Ankole.BrowserSessions` (the Ash domain) owns browser groups, outbound
  upstream OIDC ceremony states (`OidcState`), independent authentications, and
  tenant access proofs.
- `Ankole.OIDC` owns inbound OIDC authorization requests
  (`AuthorizationRequest`) and relying-party (RP) links.
- `AnkoleWeb.Session` owns sealed browser cookies, short-lived sealed ceremony
  tickets, and per-request authentication selection.

PostgreSQL stores four core records for browser state:

- **Browser group:** an ID, `revision`, `logout_revision`, default
  authentication and tenant, and expiry timestamp.
- **Authentication:** the identity source, subject, credential `scope` (`site`
  or `tenant`), scoped tenant (present for `tenant` scope and `nil` for `site`
  scope), provider authentication time (`auth_time`), challenge start time
  (`challenge_started_at`), authentication methods (`amr`), verified email or
  phone, local `authenticated_at`, expiry, and CSRF secret.
- **`PodAuthentication`:** a tenant access proof binding a verified
  authentication to one Human and `access_version`.
- **`OidcState`:** an outbound upstream OIDC redirect state containing the state
  token, browser group, target tenant, provider ID, `started_revision`, redirect
  URI, return path, optional Console return path (`console_return_to`), prompt,
  optional invitation or reauthentication pin, optional OIDC
  `AuthorizationRequest` ID, consumption state, and expiry.

When an OIDC token authenticates a request, AuthZ reads `provider_scope` from
the referenced Authentication's `scope` as part of its authentication evidence.

Every top-level operation runs inside `Repo.transact_top_level/2`, while its
`*_in_tx` counterpart composes inside a caller's transaction. Transactions
always lock the browser group row before changing authentications, proofs, or
ceremonies. Each ceremony resource enforces a single-use consumption transition;
once an `OidcState` or `AuthorizationRequest` is consumed, it cannot reopen.

An authentication lives for 24 hours, whereas an outbound `OidcState` and an
inbound `AuthorizationRequest` each live for 10 minutes. Completing a login
extends the browser group's expiry to cover the new proof, and background
cleanup retains any group while at least one valid proof references it. Code
challenges, delivery, and rate-limit windows belong to
[Authentication](Authentication.md).

## Login scopes and targets

`GET /sessions/new` serves the login shell directly without writing a database
row. The shell determines its login target from the request host and query
parameters (`tenant_id`, `return_to`, sealed `console_return`, `switch=1`,
`prompt=login`, `invitation_token`, sealed `reauth`, sealed `invitation`, or
`oauth_request`).

`AnkoleWeb.BrowserAuth.Targets` owns ceremony resolution. `AnkoleWeb.PodURL`
uses the build-selected host policy to generate login destinations, enterprise
SSO authorization URLs, and OAuth continuations. In SaaS, Pod login shells,
including privileged-Pod Console sign-in, OAuth login, and account selection,
run on `accounts`; enterprise SSO authorization and callbacks run on the target
Pod host, and successful completion returns to the Pod host, the site Console
origin (when the ceremony carries `console_return`), or the Pod's
`/oauth/authorize/resume` endpoint.

Login ceremonies target either a specific tenant or the site:

- Tenant-targeted logins cover Pod entry, Console entry (targeting the
  privileged tenant), and inbound OAuth authorization requests (targeting the
  Client's tenant recorded on `AuthorizationRequest`). A Pod login resolves its
  tenant from the request host or an explicit `tenant_id`. When an edition sets
  `pod_email_otp_disabled` on Pod hosts, `loginProviders` and email OTP
  challenge endpoints omit or reject tenant-targeted email OTP on those hosts
  while keeping tenant OIDC initiation and callbacks active.
- Outbound enterprise SSO creates an `OidcState` row when the browser visits
  `/sessions/oidc/:provider_id/authorization`, and its callback completes
  against that recorded tenant and provider. `loginProviders` returns this
  endpoint as each OIDC provider's `loginPath` on the target Pod host for Pod,
  Console, OAuth, and tenant-targeted site sign-in. On shared site sign-in hosts,
  `POST /api/v2/browser/pod-logins` resolves a workspace slug into its
  `tenantID`, `displayName`, and active OIDC `providers` (including each
  provider's `authorizationURL` on the workspace host) without exposing disabled
  tenants.
- Site-wide sign-in runs only on editions whose shared non-Pod sign-in host sets
  `site_login_host` (self-hosted FOSS deployments authenticate directly against
  a target tenant). Verifying a personal credential on a site sign-in host opens
  the workspace chooser or, when the ceremony carries a target `tenant_id` (for
  cross-host Pod sign-in, Console return, invitation acceptance, or
  personal-settings reauthentication), enters that target Pod in the same
  completion transaction when policy and membership allow. Site credential
  completion gathers the target Pod's pending member together with existing
  credential bindings, locks all candidate Principals in UID order, validates
  them, and records Pod access in one pass. A missing target membership leaves
  the site proof available for `/account`; a disabled target member or rejected
  target policy fails the login.

Every browser login adds or refreshes an independent authentication in the
browser group, and each open HTML document pins its `authentication_ref` and Pod
ID once loaded. When an operator visits `GET <console_path>` directly,
`AnkoleWeb.SpaController` checks `AnkoleWeb.Session.resolve_site_admin_session/1`.
The resolver scans proven references once and returns an administrator with its
reference, a non-administrator member, or an unauthenticated result. An explicit
`x-ankole-authentication` selection restricts resolution to that reference.
If the selected authentication or another proven authentication in the browser
group holds active `siteadmin` membership in the privileged tenant, the server
renders the Console shell immediately, pins that `authentication_ref` on the
document, and synchronizes its CSRF state without changing the browser default.
If the browser holds an active non-administrator identity in the privileged
tenant and no `siteadmin` authentication, the server responds with `403` rather
than redirecting into a login loop. Otherwise,
`AnkoleWeb.Session.seal_console_return/2` seals the Console path into a
10-minute `browser.console_return` ticket bound to the privileged tenant ID and
redirects to the privileged Pod's sign-in URL without exposing
`ANKOLE_SITE_ADMIN_CONSOLE_PATH` in plaintext query parameters; after email OTP
verification, enterprise OIDC callback, or identity selection, the browser
returns to the Console path on the site origin.

`GET /api/v2/browser/session` returns activated Pod identities, pending Pods,
and verified site authentications; a site proof with zero Pods is still a valid
session. `POST /api/v2/browser/authentications/current` accepts
`authenticationRef` and `tenantID`, verifies the proof, current login policy,
and any pending claim, and updates the browser default. Only the calling
document navigates to the target Pod, while other open documents keep their
pinned context. Initial instance setup uses isolated setup state that is
separate from normal authentication.

## Cookies and request selection

Ankole stores a browser group reference and isolated setup state in a sealed
aggregate cookie (`__Secure-ankole` on HTTPS builds and `_ankole_key` in HTTP
development, both scoped to the site's configured parent domain). This group
reference grants no authenticated access on its own and cannot list or exchange
proofs belonging to other accounts.

Browser-wide logout preserves this unprivileged group reference so that a later
login reuses the same group and renews the group cookie's expiry past the new
authentication's lifetime. As a result, a delayed HTTP response from an earlier
login still names the same group and cannot displace a newer account.

Each independent authentication is stored in its own sealed cookie, named
`__Secure-ankole-auth-<id>` on HTTPS builds and `_ankole-auth-<id>` in HTTP
development. Each proof cookie carries only that authentication's ID and
revision, uses the `SessionCookieStore` AEAD format with `HttpOnly`, `Path=/`,
and the site's configured parent domain (plus `Secure` in production), and is
replaced individually on login. No HTTP response ever serializes a combined
snapshot of all signed-in accounts. In HTTP development, cookies use
`ankole.localhost` to share state across Pod subdomains, and Vite allows module
requests from `http://ankole.localhost:4000` and its single-label Pod hosts in
both editions so that browser hosts served by Phoenix can load the login
application.

An `authentication_ref` encodes an authentication ID and revision to select a
proof rather than act as a credential. At the web boundary, Ankole requires both
a valid matching proof cookie and a live server record in the same browser
group; a group ID or a known `authentication_ref` by itself grants nothing. If
an API caller supplies a stale or unknown reference, Ankole rejects the request
without falling back to another signed-in account. Ordinary requests read and
validate only the cookie for the selected authentication ID, whereas only an
identity chooser reads all authentication cookies. Streaming connections retain
the selected proof and recheck its server state before sending each frame.

HTML shells emit `ankole-authentication` and `ankole-pod` metadata, which
browser API clients echo in the `x-ankole-authentication` and `x-ankole-pod`
request headers. Because `EventSource`, file subresources, and sandboxed Applet
`iframe`s cannot attach custom headers, Pod conversation SSE URLs,
`GET /api/v2/pod/pages/:id/files/content`, and
`GET /api/v2/pod/metadata/files/content` pass those references as query
parameters, and
`GET /pod/applet-frame/:authentication_ref/:id/:revision/*path` embeds the
authentication reference in the path. Even on these routes, the server requires
the matching proof cookie and browser group, allowing an open document to keep
its pinned identity after another account becomes the browser default. No other
API, navigation, or OIDC authorization URL accepts an identity parameter to
impersonate or switch accounts, and shareable links carry only the tenant and
resource path.

On the server, Pod API gates verify the selected tenant, authentication, current
Human access, and credential binding. The gate assigns the verified identity and
resolved tenant to the request; JSON:API uses those assignments to construct its
context. CSRF verification reads the selected authentication once, and the Pod
identity check uses the same Human record for access-version and login-policy
validation. Each new request verifies current server state.
Conversation endpoints verify either
participant membership or, for a Page-anchored thread, `page_view` permission on
its anchor Page. Console API endpoints and native Console file transfers verify
active `siteadmin` membership in the privileged tenant through
`AnkoleWeb.Session.site_admin_session/1`, rejecting ordinary Pod members with
`403`. Protected responses disallow shared caching.

In the browser, Pod query cache keys include both the authentication identity
and the tenant, and Console data selection stays local to the open document's
authentication. Changing the browser default neither mutates an already open
document nor causes a failed request to retry under another person's account.
Navigating within a Pod document to `/me` or `/settings` likewise preserves that
document's pinned authentication and tenant.

Authenticated shells and APIs use the selected authentication's CSRF secret. By
contrast, ceremony shells (`/sessions/new`, `/setup`, `/join/:token`, and
`/oauth/logout`) use the CSRF state inside the sealed browser group cookie, so
starting or repeating a login flow in one tab never invalidates another tab's
authenticated CSRF secret. Ceremony API endpoints accept either the session CSRF
token or, when called from an authenticated shell, the selected authentication's
CSRF token. Because `SameSite` cookies do not make two Pod subdomains trust each
other, `BrowserCSRF` loads the selected CSRF state for the request, verifies
both the token and an exact `Origin` match whenever `Origin` is present, and
clears process-local token state after the response finishes.

## Concurrent completion and revocation

Completing a login, logging out a single account, and logging out browser-wide
all acquire the browser group row lock and increment `browser.revision`. A newly
created or revoked authentication receives that new revision, whereas
re-verifying a live authentication preserves its `authentication_ref` and CSRF
state so pinned tabs and online RP sessions keep working. Browser-wide logout
additionally updates `browser.logout_revision`, while merely switching the
default account advances neither counter.

An outbound `OidcState` or inbound `AuthorizationRequest` can complete only when
all three conditions hold:

```text
ceremony is unconsumed and unexpired
ceremony.started_revision >= browser.logout_revision
target does not exist, or target.revision <= ceremony.started_revision
```

Ordinary email OTP verification creates a fresh authentication without binding
the code to the browser revision that was current when the email was sent, so an
unused, unexpired code can still complete after an earlier session logs out; see
[Authentication](Authentication.md#verification-ceremonies) for code lifetimes,
replacement rules, and policy checks.

Ankole keys each authentication target by `(browser, provider, subject, scope,
tenant)`. A site source uses scope `site` with `tenant_id = nil`, even when
invoked by a tenant-targeted login or OAuth request, whereas a native tenant
source uses scope `tenant` with its tenant ID, provider, and Principal UID while
storing the provider's verified external ID separately.

When OAuth triggers reauthentication for a selected account, Ankole pins that
expected authentication ID on `AuthorizationRequest`. When a user starts
reauthentication from personal settings (`/api/v2/pod/me/reauthentication`),
Ankole seals a 10-minute `browser.reauth` ticket bound to the browser ID, tenant
ID, Human UID, authentication ID, and `started_revision`, and directs the
browser to `/sessions/new` on the shared site sign-in host (with `tenant_id`)
when configured or on the Pod host otherwise, returning to `/me` on the
originating Pod host upon completion. Another permitted
login source can satisfy that reauthentication only if it resolves to the same
Human, and neither path can overwrite a target modified after
`started_revision`. Logging out a single account increments that
authentication's revision and writes a revocation tombstone, causing completion
to reject any in-flight OIDC ceremony or reauthentication pinned to that
authentication or target.

For session-bound OIDC interactions, Logto's
[email verification routes](https://github.com/logto-io/logto/blob/2c9fde42fdea88f43a802e35c9d47d14afaefa39/packages/core/src/routes/experience/index.ts#L60-L69)
load interaction details before verification, and its pinned OIDC provider
[rejects an interaction whose bound session was destroyed](https://github.com/logto-io/node-oidc-provider/blob/513c523c0e68ee6112da8c871cce86204a136163/lib/provider.js#L445-L452).
That check validates the login session context independently of OTP expiry and
single-use consumption.

| Interleaving | Result |
| --- | --- |
| A and B start OIDC ceremonies at revision 10; B completes at 11. | A can still complete because A's own target did not change. |
| Two OIDC ceremonies for A start at revision 10; one completes at 11. | Completion rejects the second callback because A's target advanced to 11. |
| A logs out before its earlier OIDC callback returns. | Completion rejects the callback against A's revocation tombstone; B remains valid. |
| Browser-wide logout precedes an earlier OIDC callback. | Completion rejects the callback because `browser.logout_revision` advanced. |
| An ordinary OTP code is sent before logout and submitted afterward. | Verification accepts the valid unused code and creates a new authentication. |
| A delayed HTTP response overwrites A's cookie with an older revision. | Only A's proof becomes unusable; B's separately named cookie remains valid. |

Revocation tombstones stay in PostgreSQL until the browser group itself is
eligible for removal, preventing a delayed OIDC callback from mistaking a
revoked target for a brand-new subject. OIDC completion, evidence writes, and
state consumption commit in one transaction. Likewise, OAuth completion binds
the verified authentication to a single `AuthorizationRequest`, which
`/oauth/authorize/resume` consumes once when issuing the authorization code.

Upstream provider network calls always run outside the browser lock. When the
callback returns, completion rechecks current state under locks acquired in
strict order: browser group first, then Principal (locking verified Humans in
ascending UID order during site authentication), and finally RP associations.

Because the server cannot control the arrival order of HTTP responses at the
browser, a delayed response that overwrites A's proof cookie with an obsolete
revision requires A to sign in again, without affecting any other signed-in
account.

## Site sources and Human recovery

`IdentityProviders.SiteSources` verifies an upstream or site source's proof and
returns its subject, actual authentication time, ceremony start time, verified
contacts, and authentication methods. Email OTP relies on a consumed durable
challenge, and the source identifier links personal credential bindings across
tenants.

Every Pod access proof requires an active Human, an available tenant, a current
credential binding and `access_version`, and compliance with the Pod's current
login policy. If a Human's membership becomes unavailable in one Pod, their
independently valid proofs in other Pods remain usable.

A fresh login targeting a specific Pod can claim a unique pending Human, and
both the public chooser and the Pod switcher can claim a pending member or a
directed invitation. When claiming a recyclable contact identifier, the ceremony
start time must be newer than the identifier's most recent release timestamp; an
older proof requires a fresh verification ceremony.

During Pod creation, `create_pod_access/2` holds the site authentication lock
while its callback creates the tenant, Human, credential binding, and
administrator membership in a single transaction. Accepting an invitation
likewise locks the tenant's member quota and records tenant access in one
transaction. Enterprise SSO completes proofs only for its configured tenant.

Restoring a disabled Human requires a fresh verification ceremony at the
restored Human `access_version`; account switching checks stored proofs and
cannot refresh verification evidence.

## Freshness and logout

Email OTP verification records a fresh authentication event. Upstream provider
adapters must supply explicit provider evidence whenever a caller requests
freshness: ordinary Lark login provides no authentication timestamp, omits
`auth_time`, and therefore cannot satisfy `prompt=login`, `max_age`, or an
essential `auth_time` claim. Reading a user profile or receiving a callback does
not count as a new authentication event, and reusing or switching sessions
preserves the original authentication timestamp.

Sensitive personal-credential updates and voluntary Pod exit check
`authenticated_at` (the local timestamp when browser verification completed),
which satisfies freshness checks for 15 minutes. Separately,
`challenge_started_at` records when the verification ceremony began so Ankole
can reject proofs started before a recycled contact identifier was released.
Reauthenticating from personal settings always starts a new verification
ceremony rather than reusing a stored proof, while upstream `auth_time`,
`prompt=login`, and `max_age` continue to enforce OIDC provider evidence rules.

Signing out of a Pod (or the Site Console, which binds to the privileged Pod)
revokes access for that Pod while leaving other signed-in Pods intact. When a
`site` authentication still holds `PodAuthentication` rows in other Pods, Ankole
removes only the target Pod's `PodAuthentication`, ends its online RP
associations in that Pod, cancels pending `AuthorizationRequest` and `OidcState`
rows for that Pod, and preserves the `site` authentication cookie for the
remaining Pods. When the authentication is `tenant`-scoped or the exited Pod is
its last remaining Pod, Ankole revokes the authentication row itself and clears
its proof cookie. From the Console, signing out of the privileged Pod navigates
to the Console path with `switch=1` so the privileged Pod sign-in page prompts
explicitly for an administrator account rather than auto-admitting another
signed-in account. If the exited Pod was the browser default, Ankole clears the
default rather than silently selecting another Pod. Open Pod streams recheck
their pinned proof before each frame or heartbeat ping.

Signing out all accounts (from a Pod or the Console) and confirmed RP logout
apply across the entire browser group: in one transaction, Ankole advances
`logout_revision`, revokes all authentications and online RP associations, and
cancels pending `OidcState` and `AuthorizationRequest` rows (causing any
reauthentication tied to a revoked proof to fail as well). After the transaction
commits, the HTTP response clears the individual proof cookies while retaining
the unprivileged group cookie.
The logged-out screen accepts only root-relative return destinations whose parsed
URL has the current origin and whose normalized path starts with a single slash.
It also excludes the logged-out path to prevent redirect loops; invalid
destinations use `/sessions/new`.
Revision checks ensure that neither a stale RP logout confirmation nor a delayed
response can revoke a newer browser revision or resurrect a revoked proof. RP
confirmation commits this revocation once, so subsequent back-channel logout
deliveries and cookie cleanups neither repeat the mutation nor terminate
authentications created afterward.

Logging out of a browser does not disable the Human Principal, sign out other
browsers, or sign out the upstream identity provider. Refresh tokens granted
with `offline_access` retain their OIDC lifetime until they expire or the Human
is disabled; see [OIDC Server](OIDCServer.md).

## Expiration and cleanup

Hourly OIDC cleanup uses a single cutoff timestamp across all tenants: it first
deletes expired inbound `AuthorizationRequest` rows per tenant, and then calls
`BrowserSessions.cleanup_expired/1` once (even if a tenant sweep failed).
`BrowserSessions` deletes expired `OidcState` rows and expired browser groups
that have no retained RP associations, cascading via foreign keys to remove
their authentications and Pod proofs. Deleting a tenant removes its Pod access
proofs, outbound `OidcState` rows, inbound `AuthorizationRequest` rows, and
native tenant authentications through the tenant-deletion owner.

Finally, the `RequestHost` policy defines host classification, the shared cookie
domain, tenant origins, canonical origins, and explicit per-host route
allowlists; declaring a Phoenix route alone never exposes it on a Pod host.
