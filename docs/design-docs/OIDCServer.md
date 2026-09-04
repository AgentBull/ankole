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

The server supports Authorization Code, Refresh Token, and PKCE S256. It does
not support implicit, password, client credentials, device code, dynamic
registration, introspection, revocation, logout, or a consent page.

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
providers. It stores login state in an OAuth browser session that is independent
from the Console administrator session. An active administrator session can
open an OAuth session for the same Human without another login. A normal Human
login does not create a Console administrator session.

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

A browser WebSocket sends `ankole.responses.v1` and
`base64url.bearer.phx.<base64url(jwt)>` as subprotocol values. The server selects
only `ankole.responses.v1`. The browser Origin must match an Origin derived from
that Client's registered HTTP redirect URIs. Token, UserInfo, and AI Gateway
CORS use the same derived Origins, with no wildcard or separate Origin list.
Native applications can use the Authorization header without an Origin.
