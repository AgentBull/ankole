# OpenID Connect Server

Ankole is an OpenID Connect Provider for registered relying parties (RPs).
`attesto` 2.6.1 owns the OAuth and OIDC protocol primitives. Ankole owns
Client policy, browser authentication, durable sessions, access tokens, and
PostgreSQL storage. The site has one issuer and one RSA signing key.

Client registration, configuration, group links, and the installation signing
key use Ash resources and named transaction actions. Only secret rotation can
change an existing confidential Client's secret. Ordinary configuration cannot
replace its ID or public/confidential type. The key initialization action
returns the installed record on conflict without changing its key or timestamps.
The SigningKey process still validates the stored key before publishing its
runtime projection. Native tables, keys, and constraints retain Ecto migrations.

OIDC sessions, logout confirmations, and logout deliveries use the same Domain.
Session actions preserve the original authentication binding, extend expiry with
`GREATEST`, and retain the first revocation and logout markers. Logout delivery
actions own the pending, delivering, delivered, and failed transitions. A
delivered record cannot restart or consume another attempt. Native constraints
also enforce positive access and authentication versions and nonnegative
browser revisions and delivery attempt counts. Historical sessions can retain a
cleared authentication reference. A composite foreign key also binds each
authentication reference to the Session's browser. Removing that reference
retains the immutable browser and authentication revision history.

Authorization codes, refresh tokens, and refresh families also use named
transaction actions. A Code can be consumed once and finalized once. Its replay
facts cannot be replaced after finalization. A Refresh can record its successor
once. The redaction action can remove retry ciphertext only after its deadline;
it retains the consumption tombstone. Family actions cannot change the original
Session or absolute deadline, and repeated revocation retains its first marker.
Native composite foreign keys bind each credential's Client and Human to its
Session and each refresh token's family to that same Session. The context CHECK
also binds the stored protocol JSON to those native columns.

## User and RP contracts

- A registered RP can sign in a Human with Authorization Code and PKCE S256.
- A browser can reuse a valid authentication, select another account, or obtain
  fresh proof for `prompt=login` and `max_age`.
- The ID token and UserInfo return `sub` and the profile fields allowed by scope.
- An RP that requests `offline_access` can renew access for at most 30 days.
  Each successful renewal rotates the refresh token.
- An authorized RP can request `ai_gateway.write`. Agents use their existing
  30-day Agent tokens for the AI Gateway.
- Revocation, a changed Human access version, a disabled Human, a suspended
  tenant, a disabled Client, or reduced Client scopes takes effect when a
  credential is used.
- RP logout requires browser confirmation. Back-Channel Logout reaches each
  registered RP through durable delivery state.
- Discovery and JWKS expose the implemented endpoints and the installation key.
- Only confidential Clients can introspect tokens. A Client can inspect only its
  own tokens.

## Protocol and product ownership

`Attesto.AuthorizationRequest` validates the protocol request and decides whether
an error can use the registered redirect URI. An invalid Client or redirect URI
returns a direct error. A trusted redirect receives subsequent protocol errors.
Ankole accepts only query responses, requires `openid`, and limits scopes to the
Client's configured scopes. Request objects, request URIs, JARM, and DPoP are not
supported or advertised.

The supported prompts are `none`, `login`, `select_account`, and `consent`.
`consent` follows the normal login policy. Ankole reads the normalized prompt
list and `max_age` from Attesto. The `auth_time` essential claim requires a known
authentication time. Other unimplemented claim requests do not reject login.

`Ankole.OIDC.LoginPolicy` owns identity-provider restrictions, authentication
reuse, account selection, and the need for fresh authentication. Browser
transactions store this normalized policy input. Ankole does not create a second
identity system for OIDC: Human Principals and their access versions remain the
identity and revocation authority.

### Upstream identity-provider authentication

`Ankole.IdentityProviders.OIDC` uses `AttestoClient.IDToken` to verify upstream
ID Tokens before an adapter can create or update a Human. Google Workspace,
Microsoft Entra ID, and Slack require a signed ID Token. The verifier checks the
configured issuer, client audience, signature, expiry, and nonce. The browser
transaction's random upstream state also serves as its nonce. UserInfo must
have the signed subject. Entra's signed tenant and object IDs must match the
configured directory and the Graph user.

The verified `auth_time` passes through the adapter, login boundary, browser
authentication, and Ankole's ID Token. A normal login can have no `auth_time`.
Ankole does not replace a missing upstream authentication time with its own
clock.

Only adapters with `oidc_fresh_authentication` can serve requests that require
an authentication time. Entra supports this capability. Its authorization
request carries the nonce, `prompt=login` and `max_age=0` when forced login is
required, the requested positive `max_age`, and the
essential `auth_time` claim. A response without the required signed time fails.
For `prompt=login` and `max_age=0`, the signed time must be at or after the
stored provider-selection time. Positive `max_age` limits the elapsed time at
verification. Google and Slack do not advertise this capability because their
login contracts do not guarantee forced authentication. Account selection or
consent does not prove fresh authentication.

## Authorization and token issuance

`Ankole.OIDC.Grants` creates an OIDC session and calls
`Attesto.AuthorizationCode.issue/3` in one database transaction. The code expires
in 60 seconds. PostgreSQL stores its SHA-256 digest and PKCE challenge, never the
plaintext code.

Authorization holds the tenant parent lock before the browser serializer and
the live Human lock. It locks the Client before an existing OIDC session. The
browser serializer permits one session creation for that Client and
authentication revision; a repeated authorization extends that row without
replacing its original authentication facts. Code insertion stays in the same
transaction. A concurrent Client deletion therefore waits before it can lock
the session through its cascade.

A code presentation calls `Attesto.AuthorizationCode.redeem/4` before the token
issuance transaction. `CodeStore.take/1` atomically marks it consumed. A wrong
Client, redirect URI, verifier, or expired grant cannot restore the code. Token
issuance then checks the Client, granted scopes, OIDC session, active Human, and
AI Gateway policy. The Human row is held with `FOR SHARE` during issuance.

Ankole issues the existing RS256 `at+jwt` access token with a 30-minute lifetime.
Its audiences, `client_id`, `sid`, `sub`, `subject_type`, and `token_use` semantics
remain unchanged. `Attesto.IDToken.mint/4` signs the ID token once. It includes
`sid`, the requested nonce, `at_hash`, and the original `auth_time` when known.
`Ankole.OIDC.Claims.project/3` is the common owner of scope-based profile claims.

After the complete response is ready, Attesto finalizes the code. Finalization
records the issued refresh family, when present, and the replay retention
boundary. The explicit `finalized` flag distinguishes a completed grant from a
consumed code whose downstream issuance failed. A replay of a completed grant
revokes its OIDC session and refresh family. A failed issuance leaves the code
spent and does not create a false completed-grant replay marker.

## Refresh storage and rotation

`Attesto.RefreshToken` owns issuance, scope narrowing, rotation, retry recovery,
and reuse detection. `Ankole.OIDC.RefreshStore` implements the PostgreSQL
transaction boundary. The family row owns the absolute 30-day deadline and a
sticky revocation marker. Each token has a digest, family ID, generation,
canonical protocol context, expiry, and consumption state. A unique constraint
on `(family_id, generation)` permits only one child at each generation.

Issuance, rotation, and family revocation lock the tenant, subject Principal,
and Client with `FOR KEY SHARE`, then the OIDC Session with `FOR UPDATE`, then
the family and parent token. `Ankole.OIDC.Sessions` owns the shared credential
parent locks. The subject lock uses its globally unique UID.
This follows the native foreign-key parent order and prevents deletion or Human
revocation from reversing those locks. The Session lock also serializes
revocation across its families. Rotation checks family revocation,
parent expiry, and the child contract before it writes the consumed parent and
inserts the child in one transaction. An integrity conflict revokes the family.
A revoked family rejects later insertion and rotation.

For 10 seconds, an identical retry can recover the exact successor token if that
successor is still the unconsumed leaf. PostgreSQL stores this credential-equivalent
retry bundle with authenticated encryption, bound to the parent digest. Reads
hide expired retry credentials in the returned value without changing storage.
Cleanup removes their ciphertext after the retry deadline. Consumed records
remain available for replay detection. Reuse outside the grace window, or after
the successor advances, revokes the family and its OIDC session.

A refresh request checks the requested `openid` scope and Client scope policy
before rotation. After rotation it checks the OIDC session, Human, and Gateway
policy. A failed business check revokes the rotated family. Refresh responses
contain an access token and successor refresh token; they do not contain a new
ID token.

## Client authentication, UserInfo, and introspection

Public Clients supply `client_id` only. Confidential Clients use
`client_secret_basic`; form secrets and client assertions are rejected. Client
authentication uses `Plug.BasicAuth`, form decoding, and a constant-time secret
comparison. An Authorization header with invalid credentials or an unsupported
scheme receives a Basic challenge.

UserInfo accepts a case-insensitive Bearer header and POST form `access_token`.
The common access-token verifier validates the signature, current Client, and
OIDC session once and returns that verified context to UserInfo. UserInfo then
checks the Origin and projects the current Human profile. It does not verify the
same token or OIDC session a second time.

Introspection requires a confidential Client. Ankole validates an access token
through the same verifier, or reads an unconsumed, unexpired refresh token in a
live family and validates its OIDC session. A credential from another Client
returns `active: false`.

## Keys, issuer, and rolling deployment

`Ankole.OIDC.SigningKeyRecord` is a site row. Its encrypted PKCS#1 private key,
public JWK, and key ID survive deployment. The `SigningKey` process verifies the
stored key before it publishes an immutable runtime cache. First startup creates
the key when no record exists. An existing key that cannot be decrypted or does
not match its stored public identity stops startup instead of replacing it.
`Ankole.OIDC.Keystore` exposes the cached key to Attesto. Attesto owns JWK
conversion, the RFC 7638 key ID, JWKS, and discovery metadata. `Ankole.OIDC` owns
the supported protocol policy and discovery projection. The HTTP controller
passes requests to that context. Attesto currently advertises DPoP without a
configuration switch, so the projection removes that unsupported capability.

`Ankole.TokenSigning` reads the issuer from its own application configuration.
SaaS uses its console origin for the same setting. The migration preserves the
exact previous issuer value. Only development and test builds can use an HTTP
issuer with a valid host and no query, fragment, or userinfo. This local exception
validates the Principal kind and keystore callbacks before constructing the
configuration. Production builds reject HTTP issuers and use
`Attesto.Config.new/1` for HTTPS configuration.

The storage upgrade retains existing refresh digests and absolute expiry times.
Each existing token becomes generation 0 of its own family. The hash algorithm
is unchanged. Existing access tokens, Agent tokens, ID-token logout hints, and
signing keys remain valid. Existing authorization codes cannot be converted from
their one-way challenge hashes; those short-lived grants must be requested again.

## Logout and cleanup

`Attesto.EndSession.parse/2` verifies ID-token hints, including expired hints,
and binds an explicit Client to the hint audience. Ankole also checks the OIDC
session and the permitted recent-logout window. The browser must confirm the
request before Ankole ends its login. `Attesto.EndSession.confirm_redirect/2`
checks the exact registered return URI and appends `state`.

Back-Channel Logout remains a durable Ankole delivery queue. Attesto signs each
`logout+jwt` with `sub`, `sid`, and the required logout event. Delivery attempts,
backoff, and deadlines remain in PostgreSQL.

The confirmation action cannot change the browser ID or revision and only
confirms an unconsumed request. Cleanup uses atomic resource deletes. Its
session retention predicates check codes, refresh tokens, and undelivered
logout records in the delete statement.

Credential cleanup preserves finalized code markers through their replay
retention deadlines, removes expired refresh records after retry retention,
redacts expired successor credentials, and removes eligible session and browser
state. Every tenant row uses the explicit `Ankole.Repo` tenant context.
