# OIDC Server

The control plane is the OpenID Provider for one Ankole installation. It uses
Boruta 2.3.8 for OAuth 2.0 and OpenID Connect protocol processing. Ankole owns
Client administration, Human identity, persistence, token policy, and the web
routes. It does not use Boruta's administration UI, identity store, or gateway.

## Protocol Surface

The public protocol routes are:

- `/.well-known/openid-configuration`
- `/.well-known/jwks.json`
- `GET /oauth/authorize`
- `POST /oauth/token`
- `GET` and `POST /oauth/userinfo`
- `POST /oauth/introspect`
- `GET` and form-encoded `POST /oauth/logout`

The server supports Authorization Code, Refresh Token, and PKCE S256. It does
not support implicit, password, client credentials, device code, dynamic
registration, token revocation, front-channel logout, or a consent page.

[Offboarding protocol additions](#offboarding-protocol-additions) define the
Back-Channel Logout and Introspection contracts.
[Authentication and browser logout](#authentication-and-browser-logout) defines
the related protocol contracts.

An OIDC Client is public or confidential. A public Client authenticates at the
token endpoint with its `client_id`. A confidential Client uses
`client_secret_basic`; no other Client authentication form is valid. Redirect
URIs match exactly. HTTP redirect URIs must use HTTPS, except for localhost.
Native redirect URIs can use a safe application scheme.

The scope vocabulary is `openid`, `profile`, `email`, `offline_access`, and
`ai_gateway.write`. Every authorization request includes `openid`. The server
issues an OIDC Refresh Token only when the request includes `offline_access`.

## Human Login

An existing active Human Principal is the Boruta Resource Owner. The
authorization endpoint uses the existing local-password and external identity
providers. A durable browser record stores separate OAuth and Console
authentication contexts. They can identify only the same Human. An active
administrator session can open an OAuth context for that Human when Client
source and freshness rules permit reuse. A normal Human login does not create
a Console administrator context.

[Browser Sessions](BrowserSessions.md) defines the lifecycle,
authentication context, and concurrent-request rules. Console permission remains
an independent AuthZ check.

The authorization endpoint completes authorization after login. It does not
store user consent. The administrator's Client scopes, allowed groups, and
allowed models are the authorization boundary.

## Shared Token Endpoint

`POST /oauth/token` also serves the Console. Request shape selects one branch
before authentication:

- The `urn:ankole:params:oauth:grant-type:browser-session` grant and a Refresh
  Token request without Client credentials use the Console branch. This branch
  requires an active administrator session, the same Origin, and CSRF proof. It
  rejects every OIDC Client credential.
- Authorization Code and Refresh Token requests with the declared Client
  authentication shape use the OIDC branch. This branch does not use the
  browser cookie.

The Console has no OIDC Client record and receives no ID Token.

## Keys, Tokens, and Persistence

The installation has one RSA-2048 signing key. Startup loads it from PostgreSQL
or creates it in one transaction on first use. The private key is encrypted with
a key derived from `SecretKeyBase`. The public key is one JWK. Startup fails if
the stored private key cannot be decrypted or does not match the stored public
key. There is no signing-key administration or rotation system.

Agent Access Tokens, Console Access and Refresh Tokens, OIDC Access Tokens, and
OIDC ID Tokens use this RS256 key. A Client secret authenticates only its
confidential Client. It never signs a token. Access Tokens use `typ=at+jwt` and
include `iss`, `sub`, `aud`, `scope`, `subject_type`, `token_use`, `jti`, `iat`,
`nbf`, and `exp`. Console Refresh Tokens use `typ=rt+jwt` and remain bound to the
current Console browser session by `sid_hash`.

OIDC Access Tokens live for 30 minutes, and ID Tokens live for 5 minutes. An
Authorization Code lives for 5 minutes and can be used once. An OIDC Refresh
Token has a 30-day absolute lifetime and rotates atomically on use. Only the
digest of an Authorization Code or OIDC Refresh Token is stored. Client secrets
are encrypted and returned only at Client creation or secret rotation. Access
Tokens, ID Tokens, users, and consent are not duplicated in OIDC storage.

`oidc_sessions` stores each Client, browser generation, Human access version,
verified provider, authentication time, authorization expiry, session end, and
authorization revocation. Its UUID is `sid`. Authorization Codes and Refresh
Tokens reference this row. `oidc_logout_requests` binds a validated logout
request to one browser generation. `oidc_logout_deliveries` stores the registered
endpoint, target session, delivery state, attempts, retry time, deadline, and
bounded error. These records remain available after token expiry; expiry alone
is not proof that an RP session ended.

## AI Gateway

A Client with `ai_gateway.write` has at least one allowed Principal group and
one Client-specific custom LLM alias. Each alias uses the Agent custom model
profile shape: a custom name, required description, provider, model, optional
context length, and request options. Custom names match
`[a-z][a-z0-9_-]{0,63}` and cannot use a fixed Agent profile name. Raw
`provider_id/model` selectors are not part of the Client contract. Static and
computed group membership is read through AuthZ for each request. Removing this
scope clears the Client's group and alias policy in the same transaction.

Each AI Gateway HTTP request and each WebSocket `response.create` checks the
RS256 token, active Human, active Client, current scope, current group
membership, and current model policy. `/models` returns only allowed models that
are currently available, identified by the Client aliases. An OIDC Human cannot
use raw provider selectors, fixed Agent profiles, or aliases from an Agent or
another Client.

HTTP `POST /responses` still rejects `store=true`. Stateful storage uses the
existing Responses WebSocket. Stored data uses the Human Principal uid as
`subject_uid`, so another Human cannot read it. Client deletion does not delete
this data.

For each stored WebSocket request, AIGateway records `oidc_client_id` from
the freshly validated grant in its own message metadata. Caller metadata
cannot set this origin. The Human still owns the conversation; a continuation
through another Client records that Client on the new request.

Brain registers one `oidc_client` Source per Client with stored terminal
requests. Its maintenance sweep enqueues learning through the existing Source
job. Each Client/conversation pair becomes one Source-owned `media` page.
The Brain maintainer Agent's `light` profile performs extraction; Client model
aliases continue to control the external inference request only. Source defaults
are configured in the Brain Sources Console. An unset default keeps each
conversation private to the submitting Human. Defaults apply when a conversation
first enters Brain; existing conversations keep their audience. Client edits
and deletion do not change that audience or remove stored knowledge.

A browser WebSocket sends `ankole.responses.v1` and
`base64url.bearer.phx.<base64url(jwt)>` as subprotocol values. The server selects
only `ankole.responses.v1`. The browser Origin must match an Origin derived from
that Client's registered HTTP redirect URIs. Token, UserInfo, and AI Gateway
CORS use the same derived Origins, with no wildcard or separate Origin list.
Native applications can use the Authorization header without an Origin.

## Offboarding Protocol Additions

[Human Offboarding](HumanOffboarding.md) uses OpenID Connect Back-Channel
Logout and OAuth 2.0 Token Introspection. Both run through the existing
OIDC/Boruta boundary, Client administration, signing keys, and control-plane
persistence; there is no parallel identity provider. The following sections
define the supported protocol profile.

### Back-Channel Logout

Follow [OpenID Connect Back-Channel Logout 1.0](https://openid.net/specs/openid-connect-backchannel-1_0.html).
Register `backchannel_logout_uri` and `backchannel_logout_session_required` in
the existing Client configuration. Advertise `backchannel_logout_supported`
and `backchannel_logout_session_supported` as true.

Send a signed Logout Token by form-encoded HTTP POST as `logout_token`. Use the
OIDC signing key and RS256. Include `iss`, `aud`, `iat`, `exp`, `jti`, `events`,
`sub`, and `sid`; exclude `nonce`. Set the standard back-channel logout event
and use `typ=logout+jwt`. The receiver must apply the specification's complete
validation and logout rules. Treat HTTP 200 or 204 as success.

Ankole chooses session-specific logout. Issue `sid` in ID Tokens and send it
in Logout Tokens. Preserve it through refresh within that session. A fresh
login after account recovery has a new `sid`. Address every recorded old
Client/session pair; do not replace these requests with a subject-only logout
that can also end a new session.

OIDC must keep enough durable Client/session association to select every
potentially live session, including sessions created without `offline_access`.
Access Token expiry alone does not prove that a Client's session has ended.
Session registration and credential issuance must respect the same disable
boundary, so a concurrent authorization cannot escape notification tracking.

Persist notification work with the disable operation. Retry temporary failures
with backoff for at least 24 hours, then retain failures for operator retry.
Use a fresh token when the previous one expires; retain the original target
`sid` and disable-operation reference. An in-flight or retried notification
must never target sessions created after recovery. HTTP success records the
Client's acknowledgement, not an independently verified business-access result.

Use only registered absolute callback addresses without fragments. Ankole's
deployment policy requires HTTPS in production; permit HTTP only for an
explicit confidential development Client on a trusted network. Do not
follow redirects or allow an unvalidated callback target. The control-plane
deployment must be able to reach the registered callback.

Client registration stays administrator-managed. Ankole does not provide
dynamic registration or front-channel logout. Browser logout uses the same
notification owner, with the scope defined below.

### Token Introspection

`POST /oauth/introspect` follows
[RFC 7662](https://www.rfc-editor.org/rfc/rfc7662.html). Accept form-encoded
`token` and optional `token_type_hint`; a hint cannot exclude other supported
token types from lookup. Return JSON with boolean `active`. A valid query for
an unknown, inactive, or out-of-scope token returns only `{"active": false}`.
Invalid caller authentication returns HTTP 401, not an inactive-token result.
A disabled querying Client also fails authentication. Apply inactive-token
rules only after authenticating the caller, and apply the RFC error rules to
malformed requests.

The Ankole profile supports its OIDC Access and Refresh Tokens. An enabled
confidential Client authenticates with `client_secret_basic` and can inspect
only tokens issued to that Client. Do not accept Console tokens, Agent tokens,
ID Tokens, or a public `client_id` as caller authentication. Public Clients
retain their existing login flows; Ankole does not give them anonymous
Introspection access or a secret to embed in an application.

Read the current token, Human, Client, and revocation state. A disabled Human,
disabled Client, revoked authorization, expired token, or consumed Refresh
Token is inactive. Apply the existing scope-validity rules. A restored Human
does not make an old token active again. An active response includes `iss`,
`sub`, `client_id`, `scope`, and `exp` from the verified authorization. Do not
expose disable reasons or company directory data. A dependency failure returns
a service error; it cannot produce an unverified `active: true` response.

Advertise `introspection_endpoint` and
`introspection_endpoint_auth_methods_supported: ["client_secret_basic"]` in
the existing discovery document, using the metadata definitions in
[RFC 8414](https://www.rfc-editor.org/rfc/rfc8414.html#section-2). Keep this
authentication declaration separate from the token endpoint's public-Client
support. Deployment must provide TLS and protect Client credentials and queried
tokens from logs.

### Client Integration

Ankole provides the protocol, durable notification delivery, and current
token checks. The Client owns its business session and access rules. It must validate notifications, match `sid`, make repeated logout
safe, and prevent a delayed login callback from recreating an already logged-out
session. A standard Logout Token is not an employee-status or HR event.

The Client chooses and documents its check and cache interval. Cached validity
must not outlive token expiry. The Client must handle timeouts, stale cached
results, and service recovery without interpreting an outage or ordinary token
expiry as employee departure. No fixed five-minute or other end-to-end logout
deadline is part of this contract.

## Authentication and Browser Logout

These contracts use the existing Boruta protocol boundary.
[Browser Sessions](BrowserSessions.md) owns authentication context and pending
login state. OIDC owns Client policy, authorization credentials, and RP sessions.

### Authentication Requests

Apply [OIDC Core authentication request semantics](https://openid.net/specs/openid-connect-core-1_0.html#AuthRequest).
Accept `prompt=login`, `prompt=none`, and no prompt. Reject combined `none` and
interactive values and unsupported prompt values with `invalid_request`.
`select_account` and a consent interface are not supported.

Parse `max_age` as decimal seconds from 0 through 2147483647. Reject negative,
fractional, malformed, and larger values. Use the actual authentication time,
not token issue time or profile-update time. `prompt=login` and `max_age=0`
require a new authentication. A positive age permits reuse only while the
verified authentication context meets that age. A missing authentication time
requires authentication. If `prompt=none` cannot meet these rules, return
`login_required` without interaction. Redirect errors only to a validated
Client redirect URI and preserve its `state`.

A successful authentication completes only its bound authorization transaction.
The transaction records the Client, redirect URI, scopes, `state`, `nonce`,
PKCE challenge, requested freshness, selected provider, and authenticated
Principal. Consume its completion once. Resuming this transaction does not
apply `prompt=login` again. A new request cannot use that completion proof.
Cancellation, expiry, provider failure, or an obsolete transaction cannot fall
back to a previous login.

Carry `auth_time`, provider ID, Human revocation generation, and RP `sid` from
authentication through the code and Refresh Token records. Include `auth_time`
in ID Tokens when the provider proves it, and declare it in `claims_supported`.
Ordinary Lark login omits `auth_time`; a request that requires it must use an
allowed provider with freshness evidence or fail. Refresh
preserves the original authentication time and `sid`. Set Boruta ResourceOwner
`last_login_at` from this retained context so its current-time fallback cannot
replace the authentication event. Claims requested through
the standard `claims` parameter must not silently bypass a required
`auth_time`; unsupported essential claims fail explicitly.

### Client Identity-Provider Policy

`allowed_identity_provider_ids` belongs to the existing Client configuration.
An empty list keeps the existing choice of active login providers. A nonempty
list permits only those configured provider IDs, including the existing local
password provider ID when explicitly selected. Validate IDs when saving the
Client. A removed or disabled provider does not cause a fallback to another
source. A policy with no usable provider fails with an actionable error.

Check the verified authentication source at login entry, session reuse, code
issuance, code exchange, refresh, and protected-token validation. Store this
source with credentials; do not infer it from the Principal's other identity
links. Re-read current Client policy so that a removed source cannot keep
issuing or using credentials. Apply the same rule to Introspection. This does
not change Principal identity matching or grant Console administration rights.

### RP-Initiated Logout

Follow [OpenID Connect RP-Initiated Logout 1.0](https://openid.net/specs/openid-connect-rpinitiated-1_0.html).
Expose `GET` and form-encoded `POST /oauth/logout`; publish
`end_session_endpoint` in discovery. Register
`post_logout_redirect_uris` separately from login redirects. Require exact
matching. Use HTTPS; allow HTTP only for an explicitly configured confidential
development Client. A public browser Client uses HTTPS for logout callbacks.

Accept `id_token_hint`, `client_id`, `post_logout_redirect_uri`, and `state`.
Validate hint signature, issuer, audience, and session association. When both
hint and Client ID are present, they must identify the same Client. A hint is
not an Access Token: an expired hint can identify a current or recent RP session.
Retain ended RP associations for 24 hours to resolve recent sessions. An older
or mismatched association cannot silently end the current browser session.
Invalid hints and redirects produce an OP error page without a client redirect.

The hint identifies the RP association, which can belong to a previous browser
reference or another identity. It does not select the browser to end. Cookie
removal after logout must still permit a recent hint to start a new confirmation.

Always show a logout confirmation. Bind it to the browser session and validated
request; require CSRF proof on confirmation. This also covers absent hints and
identity conflicts. A valid Client ID and registered redirect are sufficient
for the no-hint confirmation path; no Client secret enters the browser. Cancel
leaves the OP session active and displays that result on the OP page.

Confirmed logout ends the current browser's Ankole authentication through
Browser Sessions. It does not disable the Principal or end other devices.
Notify RP sessions associated with that browser through the existing
Back-Channel Logout delivery path, including the initiating RP. Complete one
bounded delivery attempt for each registered target before a successful
post-logout redirect; persist failures for retry. A redirect does not certify
that every RP received the notification. Echo `state` only to the validated
post-logout URI. Repeated logout is safe.

Browser logout invalidates pending codes and browser-bound online grants.
An explicit `offline_access` grant retains its existing absolute lifetime
after ordinary logout; Principal disablement revokes it. Logout notifications
end RP sessions and do not themselves prove revocation of offline grants.
The same browser logout service handles Console logout and RP logout.

### Expired State Cleanup

`Ankole.OIDC.Jobs.CleanupExpiredCredentials` runs once per hour. It removes
expired authorization codes, refresh tokens, and logout requests. It then
removes an expired RP association only when no code or refresh token still
references it, at least 24 hours have passed since it ended, and all of its
logout deliveries succeeded. An expired association that never ended needs
no ended-session retention period. Delivered rows are deleted with their
association, so retention cannot cause the same notification to be queued again.

Pending, in-progress, and failed deliveries retain their association and browser
record. Failed delivery records remain available for operator retry, without
an automatic deletion deadline. Explicit offline grants also retain their
association until their credentials expire. Browser Sessions then removes its
eligible expired state through its own cleanup operation.

Manual delivery retry makes a scheduled retry job available immediately. It
reuses the existing unique job when one is waiting; an executing attempt keeps
its execution. Automatic retry retains the existing backoff and deadline.

### Client Responsibilities

The RP owns its local session, authorization rules, and in-flight login or
refresh operations. Local logout must invalidate those pending operations so a
late response cannot restore local tokens. Clear local state even when the OP
is unavailable, and distinguish that result from completed OP logout. Discover
the logout endpoint, keep login and logout callback registration separate, and
validate the returned `state`.

For authentication, validate the ID Token signature, issuer, audience, expiry,
and requested `nonce` and `auth_time`; compare UserInfo `sub` with the ID Token.
A display name or decoded but unverified JWT is not identity proof. OIDC does
not allocate the RP's business permissions.
