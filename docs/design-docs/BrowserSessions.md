# Browser Sessions

Ankole stores independent browser authentications in PostgreSQL. An active
selection supplies the default for a new page. Each open Pod page keeps its own
authentication and tenant. A change to the default cannot change that page's
identity.

## Ownership and records

`Ankole.BrowserSessions` owns these records:

| Record | Facts |
| --- | --- |
| `browser_sessions` | Group ID, `revision`, `logout_revision`, expiry, active authentication and tenant. |
| `browser_authentications` | Browser, provider, opaque subject, purpose, tenant where applicable, revision, authentication time, CSRF state, expiry, and revocation. |
| `browser_pod_authentications` | Authentication, tenant, Human Principal UID, and the verified `access_version`. |
| `browser_login_transactions` | Browser, `started_revision`, purpose, fixed target, one-use state, selected provider, expected subject, and CSRF state. |

`AnkoleWeb.Session` owns cookie transport and selection from proofs that the
browser holds. IdentityProviders verifies credentials. Principals owns Human
identity and revocation. AuthZ owns permissions. OIDC owns Client policy, grants,
RP associations, and logout delivery. These records do not replace
[Principal](Principal.md) or the matching rules in that owner.

A browser and its authentication records belong to the site. A Pod access proof
belongs to its tenant and requires an explicit Repo context. A Principal belongs
to one tenant. Its UID remains globally unique and opaque.

An authentication lives for 24 hours. A login transaction lives for 10 minutes.
A completed authentication extends the group's expiry to cover that proof.
Cleanup cannot delete a group while a valid proof still needs it.

## Login purposes and targets

`pod`, `console`, and `oauth` transactions fix the tenant before credential
verification. Pod entry uses an explicit `tenant_id`, the valid active context,
or the privileged tenant as the default organization. This default does not
require administrator membership. Console fixes the privileged tenant and
requires siteadmin. OAuth fixes the validated Client's tenant.

A `site` transaction has no tenant. Only a trusted, build-declared site source
can complete it. Other transactions cannot omit their target tenant. A callback
enters the recorded tenant; it cannot substitute one from query parameters.

Site authentication also records `console_authenticated`. Only a successful
`console` login can set it. A site account login through Pod, OAuth, or the
account center cannot grant Console access. Console requests also check the
current privileged tenant, Human access proof, and siteadmin membership.

Pod login retains the browser's existing work identities. Its account chooser
selects a proven identity for the fixed target tenant without signing out.
Console and OAuth retain their identity replacement rule:
a new identity ends a conflicting Console or OAuth context. Contexts for the
same Principal can remain, with their original provider and authentication time.
A native Pod login does not grant Console access, including for an administrator.

The core also accepts `mode: :add` to preserve other authentications. A trusted
HTTP entry can assign `browser_login_mode: :add` before it calls the public
Router. This applies to public OAuth continuations as well as private login
routes. Request parameters cannot set this mode. FOSS does not provide a site
account product or a multi-Pod account center. `GET /.internal-apis/session`
lists the Pod identities that this browser group has proved, one for each
person and tenant. `PUT /.internal-apis/sessions/active` makes one of them the
browser default. It does not change an open document's pinned identity.

Setup state remains separate. It cannot complete a normal login or replace a
missing authentication proof.

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
existing `SessionCookieStore` AEAD format, HttpOnly, the site's configured
parent domain, and `Path=/`; production also requires Secure. Development uses
`ankole.localhost` to permit sharing across Pod subdomains. Login replaces only its own proof
cookie. No response serializes a snapshot of all logged-in accounts.

On a host that still holds older `__Host-ankole` and `__Host-ankole-auth-*`
cookies, the transport verifies their existing group and authentication records
and copies valid proofs into the shared cookies. This does not mint an identity
or change the browser's active account. Revoked proofs cannot migrate. The old
host cookies expire after this request.

`authentication_ref` encodes an ID and revision. It selects a proof; it is not
a credential. The web boundary requires the matching valid cookie and server
record, in the same browser group. A group ID or a known reference alone grants
nothing. An explicit stale or unknown API reference fails without fallback.
Normal requests validate only the cookie for the selected authentication ID.
Only an identity chooser reads all authentication cookies. Stream frames keep
the selected proof and check its current server state each time.

The shell emits `ankole-authentication` and `ankole-pod` metadata. Browser API
requests send `x-ankole-authentication` and `x-ankole-pod`. EventSource and file
subresources cannot send these headers, so Pod conversation event URLs and
`GET /.internal-apis/pod/pages/:id/files/content` carry the same references in
their query. These requests still require the selected proof cookie and browser
group, so an open document keeps its identity when another account becomes
active. Other API, navigation and OIDC authorization URLs cannot select another
logged-in account by adding an identity parameter. Shareable links contain only
the tenant and resource.

Pod API gates check the selected tenant, authentication, current Human access,
and binding. Conversation operations retain their participant checks. A Console
API still requires current siteadmin membership; Pod login does not open its
`/api/v1` administration scope. Protected responses cannot enter a shared cache.
Pod query keys include both identity and tenant. Console data selection is local
to the document's authentication. Switching the browser default does not change
an open document or cause a failed request to retry as another person.

CSRF state belongs to the selected authentication or a valid login transaction.
Cancellation, consumption, expiry, and browser logout invalidate a transaction's
CSRF state through the same transaction checks. BrowserCSRF loads that state
for the request and clears process-local token
state after the response. Login B does not replace A's CSRF state. Unsafe
requests require a valid token and, when supplied, an exact matching Origin.
SameSite does not establish that two Pod origins trust each other.

## Concurrent completion and revocation

Login completion, single exit, and global exit lock the browser row. Each
mutation advances `browser.revision` and writes that value to the affected
authentication. Global exit also writes `logout_revision`. Selection alone does
not advance either counter.

A login can complete only when:

```text
transaction is pending and unexpired
transaction.started_revision >= browser.logout_revision
target does not exist, or target.revision <= transaction.started_revision
```

The target key is browser, provider, subject, purpose, and tenant. A site source
uses purpose `site` and no tenant, including when an OAuth transaction invokes
it. A native source uses its tenant, provider, and Principal UID. The provider's
verified external ID is retained separately.

A transaction selected for reauthentication also fixes the subject. It cannot
return another account or overwrite a subject changed after selection. An
explicit identity selection records the current revision as its comparison
point. Single exit cancels transactions already bound to that authentication;
an unknown subject is checked against its retained target record at completion.

| Interleaving | Result |
| --- | --- |
| A and B start at revision 10; B completes at 11 in add mode. | A can complete if A's own target did not change. |
| Two A flows start at 10; one completes at 11. | The other fails. |
| A exits before its old callback returns. | The retained revocation record rejects that callback; B remains valid. |
| Global exit precedes an old callback. | The logout revision and cancelled transaction reject it. |
| A late HTTP response writes an old A cookie. | Only A's proof becomes unusable; B's differently named cookie remains valid. |

Revocation records remain until the group can be removed. They cannot disappear
while an old transaction could mistake the target for a new subject. Completion,
evidence writes, and transaction consumption commit together. OAuth completion
remains bound to one request and is consumed once for code issuance.

Provider network requests run outside the browser lock. Completion rechecks
current state. Use the order browser, then Principal, then RP associations.
Site authentication locks verified Humans in stable UID order.

The server cannot order HTTP responses at the browser. After a late response
replaces A's cookie with an obsolete revision, A must sign in again. This
recovery cannot invalidate another authentication.

## Site sources and Human recovery

`IdentityProviders.SiteSources` accepts source IDs and modules from the selected
source build. The module verifies its credential and returns an opaque subject
and actual authentication time. Tenant provider configuration cannot register
one of these reserved IDs. The core has no foreign key to a private account table
and no special knowledge of an account email or a Solid WebID.

A site login reads only existing external identity bindings. For each active,
available Human, it stores the access version verified during that login. It
does not create members or match contact data across tenants. Each protected
request checks that the binding and Human version remain current. A disabled
Human gets no new proof. An unavailable Pod does not stop access to another Pod.

Restoration does not refresh an old proof or an authentication completed during
disablement. A new real authentication must verify the restored Human. This uses
HumanAccess's existing access version and transaction revocation check; it adds
no restoration clock. One Human's revocation does not end the same account's
other Pod identities.

`create_pod_access/2` locks the site authentication before it invokes the owning
creation transaction. The callback creates the tenant, Human, and binding; the
core records initial access and commits them together. It rejects a previously
revoked Human presented as a newly created identity.

`connect_pod_access/4` requires a second live authentication for the target Human.
It locks that Human before it invokes the explicit binding operation. Only then
can it record that verified access version. Both operations preserve the parent
revision, authentication time, and expiry. Ordinary switching cannot invoke
these operations to refresh a proof.

`consume_login/4` consumes a pending transaction in its fixed context without
minting an authentication. A private handoff can use this one-use boundary; it
still owns its origin, state, and parent-proof checks.

The handoff owner computes and stores its code digest. It uses the login
transaction's ten-minute expiry and preserves the stored digest format while
pending transactions can still be consumed.

`AnkoleWeb.Session` seals each handoff's browser state in a separate host-only
cookie. Its random name lets concurrent entries keep independent state. A
successful handoff can write the already verified parent authentication with
`put_authentication/3`; it cannot extend that authentication's time or expiry.

## Freshness and logout

Local password verification establishes a new authentication event. A provider
adapter must supply evidence for requested freshness. Ordinary Lark login has
no such evidence and omits `auth_time`; it cannot satisfy `prompt=login`,
`max_age`, or essential `auth_time`. A profile read or callback time is not a
new authentication. Reuse and selection preserve the event's actual time.

Single exit revokes one authentication and its online RP associations. Its
other Pod proofs fail with the parent. Other authentications remain usable.
If it was active, the default is cleared; another account is not selected.
A Pod stream rechecks its original proof before each frame or ping.

Console logout and confirmed RP logout retain browser-wide semantics. They end
all authentications, pending login and password transactions, and online RP
associations in one transaction. The response drops the individual proof cookies
after commit and keeps the group reference. A stale RP logout confirmation cannot
end a newer browser revision. A late response cannot restore a revoked proof.
RP confirmation commits this revocation once. Back-channel delivery and cookie
cleanup do not repeat it or end an authentication added after that commit.

Browser exit does not disable a Human, end another browser, or log out an
upstream provider. Existing `offline_access` grants retain their OIDC lifetime;
Human disablement still revokes them. See [OIDC Server](OIDCServer.md).

## Migration and cleanup

The independent-authentication migration ends old online RP associations, clears
pending login and logout requests, and removes the single-value `admin_auth`
and `oauth_auth` fields. Existing browsers must sign in again. It retains
Principals, bindings, permissions, work, offline grants, and logout delivery
records. It does not fabricate authentication time from an old cookie.

The hourly OIDC cleanup uses one cutoff across all tenants. It calls
`BrowserSessions.cleanup_expired/1` once after tenant cleanup attempts, including
when a tenant failed. Browser Sessions removes expired transactions and expired
groups with no retained RP association. Foreign keys then remove their
independent authentications and proofs. Tenant deletion removes its access
proofs and native authentication rows through the existing deletion owner.

The edition Host policy declares classification, the shared cookie domain,
tenant origins, and canonical origins through `RequestHost` callbacks. FOSS
origins retain the request scheme and port. SaaS route admission is an explicit
Host policy; a route declaration alone does not grant access from a Pod Host.
