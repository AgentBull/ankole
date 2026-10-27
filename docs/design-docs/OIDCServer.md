# OpenID Connect Server

Ankole acts as an OpenID Connect Provider for registered relying parties (RPs).
`attesto` 2.6.1 provides the OAuth 2.0 and OIDC protocol primitives, while
Ankole owns Client policy, browser authentication, durable sessions, access
tokens, and PostgreSQL persistence. Each site exposes a single issuer URL and
signs tokens with one site-wide RSA key.

`Ankole.OIDC` is the root Ash domain for all OIDC resources, and Ecto
migrations define the underlying PostgreSQL tables, keys, and native
constraints:

- **Clients and signing keys**: Registering or updating a Client modifies the
  Client row and its group links together inside `Repo.transact_top_level/2`
  (`create_client`, `update_client`), exposed to the Console at
  `/api/v2/oidc-clients`. Client deletion, secret rotation, and signing-key
  initialization each execute as a single SQL statement. Ordinary configuration
  updates cannot alter a Client's ID or switch its public/confidential type, and
  only the secret-rotation action can replace an existing confidential Client's
  secret. Initializing the signing key is idempotent: on conflict, it returns
  the installed record without modifying its key material or timestamps, and
  the `SigningKey` process validates the stored key before publishing its
  runtime projection.
- **Authorization requests, sessions, and logout state**: When
  `/oauth/authorize` needs interactive sign-in or account selection, Ankole
  persists a 10-minute tenant-scoped `AuthorizationRequest` and redirects the
  browser to `/sessions/new?oauth_request=<id>`. Authorizing a session runs as
  a single upsert keyed on the Client and authentication revision; it extends
  expiry only to a later timestamp, preserving the original authentication
  binding and never shortening an active Session. Session actions preserve the
  earliest revocation and logout timestamps, while logout-delivery actions
  drive transitions across `pending`, `delivering`, `delivered`, and `failed`
  (once a delivery reaches `delivered`, Ankole rejects restarts or extra
  attempts). Native database constraints enforce positive access and
  authentication versions alongside nonnegative browser revisions and delivery
  attempt counts. A composite foreign key ties each session's authentication
  reference to its browser, and clearing that reference on historical sessions
  leaves the immutable browser and authentication-revision history intact.
- **Codes, refresh tokens, and refresh families**: Named transaction actions
  enforce single-use invariants across credentials. An authorization code can
  be consumed once and finalized once, after which its replay metadata is
  immutable. Likewise, a refresh token can record its successor at most once,
  and the redaction action removes retry ciphertext only after the retry
  deadline while keeping the consumption tombstone. Refresh-family actions
  never alter the original Session or the absolute 30-day deadline, and
  repeated revocations retain the first revocation marker. Native composite
  foreign keys bind each credential's Client and Human to its Session—and bind
  each refresh token's family to that same Session—while a `CHECK` constraint on
  the protocol context JSON keeps its embedded identifiers aligned with those
  relational columns.

## User and RP contracts

- A registered RP can sign in a Human using the Authorization Code flow with
  PKCE `S256`.
- During authorization, a browser can reuse an active authentication, switch
  accounts, or complete fresh authentication for `prompt=login` and `max_age`.
- Both the ID token and the UserInfo endpoint return `sub` plus the profile
  claims permitted by the granted scopes.
- An RP granted `offline_access` can refresh tokens for up to 30 days, and each
  successful refresh rotates the refresh token.
- An authorized RP can request the `ai_gateway.write` scope, whereas Agents
  authenticate to the AI Gateway with their own 30-day Agent tokens.
- Whenever a Client presents a credential, Ankole immediately enforces session
  revocation, Human access-version bumps, disabled Humans, suspended tenants,
  disabled Clients, and narrowed Client scopes.
- RP-initiated logout requires interactive confirmation in the browser, and
  Back-Channel Logout notifies each registered RP through a durable delivery
  queue.
- Discovery and JWKS endpoints publish the supported OIDC metadata and the site
  signing key.
- Token introspection is restricted to confidential Clients, and each Client can
  introspect only tokens issued to itself.

## Console Client Management

Tenant administrators manage OIDC Clients in the Console via
`/api/v2/oidc-clients`. Calling `GET /api/v2/oidc-clients/login-sources` lists
both the tenant's identity providers and the registered site login sources
available for a Client's sign-in policy.

Rotating a secret via `POST /api/v2/oidc-clients/:id/secret-rotations` requires
the Client update permission and a confidential Client. The endpoint returns
the new plaintext secret once with `Cache-Control: private, no-store`, while
all Client read endpoints omit both the secret and its ciphertext. In the
Console UI, a modal displays the rotated secret and clears it from memory as
soon as the operator navigates away from that Client.

## Protocol and product ownership

`Attesto.AuthorizationRequest` parses the incoming OAuth request and determines
whether errors may redirect back to the RP. If the `client_id` or
`redirect_uri` is invalid, Ankole renders a direct error response; once both
are verified, Ankole sends subsequent protocol errors to that registered
redirect URI using query parameters only. Every request must include the
`openid` scope and stay within the Client's configured scopes. Ankole neither
supports nor advertises request objects, `request_uri`, JARM, or DPoP.

Supported `prompt` values are `none`, `login`, `select_account`, and `consent`
(where `consent` follows the standard login policy). Ankole reads the
normalized prompt list and `max_age` from Attesto: requesting `auth_time` as an
essential claim requires a known authentication timestamp, while other
unimplemented claim requests are ignored rather than failing sign-in.

`Ankole.OIDC.LoginPolicy` decides which identity providers are allowed, whether
an existing browser authentication can be reused, and when account selection or
fresh authentication is required. To compute allowed providers, it intersects
the Client's configured login sources with the tenant's
`Ankole.Principals.PodLoginPolicy`—for example, excluding site `email_otp` when
`allow_email_otp` is `false`—and `AuthorizationRequest` persists the normalized
request parameters. OIDC introduces no separate user directory: Human
Principals and their `access_version` counters remain the single source of
truth for identity and revocation.

### Upstream identity-provider authentication

Before an upstream OIDC adapter can create or update a Human,
`Ankole.IdentityProviders.OIDC` verifies the provider's ID Token via
`AttestoClient.IDToken`. Google Workspace, Microsoft Entra ID, and Slack all
require a signed ID Token matching the configured issuer, client audience,
signature, expiry, and nonce (reusing the outbound `OidcState` record's random
state token as the nonce). In addition, any UserInfo subject must match the
signed ID Token `sub`, and Microsoft Entra's signed tenant and object IDs must
match the configured directory and Graph user.

When the upstream provider supplies a verified `auth_time`, Ankole carries that
timestamp through the adapter, login boundary, browser authentication record,
and Ankole's issued ID Token. Ordinary logins may omit `auth_time`; Ankole
never substitutes its own wall clock when the upstream timestamp is absent.

Only adapters that declare `oidc_fresh_authentication` can satisfy OIDC
requests requiring a verified authentication time. Microsoft Entra supports
this capability: its outbound authorization request includes the nonce,
essential `auth_time` claim, `prompt=login` and `max_age=0` whenever forced
re-authentication is needed, and any positive `max_age`. Verification rejects
responses that omit the signed `auth_time`: for `prompt=login` or `max_age=0`,
`auth_time` must be at or after the timestamp recorded when the user selected
the provider, and for a positive `max_age`, the elapsed age at verification
must stay within that bound. Google and Slack do not advertise
`oidc_fresh_authentication` because their sign-in flows do not guarantee forced
re-authentication, and completing account selection or consent alone never
counts as fresh authentication.

## Authorization and token issuance

`Ankole.OIDC.Grants.authorize/2` executes inside `Repo.transact_top_level/2` to
create or extend the OIDC session and mint a 60-second authorization code via
`Attesto.AuthorizationCode.issue/3`. When resuming an interactive flow,
`/oauth/authorize/resume` consumes the bound `AuthorizationRequest` once and
calls `Grants.authorize_in_tx/2` in the same transaction. PostgreSQL stores
only the code's SHA-256 digest and PKCE challenge, never the plaintext code.
Each code also records the verified authentication time used for that
authorization. A fresh authentication can reuse the RP Session while its new
code records the new time. Codes issued before that authentication keep their
own time, and an unknown authentication time stays null.

Inside the authorization transaction, Ankole acquires the tenant parent lock
before the browser serializer and the live Human lock, then locks the Client
with `FOR KEY SHARE` so neither the tenant nor the Client can be removed while
the session references them. Writing the session uses a single
`INSERT ... ON CONFLICT` on `(client, authentication_revision)`: on conflict,
PostgreSQL locks the existing session row and advances its expiry only if the
new expiry is later, ensuring repeated authorizations never overwrite the
original authentication binding or shorten a session used by live refresh
tokens. Concurrent first-time authorizations converge on the same row, and
because code insertion runs in the same transaction, any concurrent Client
deletion blocks until the transaction finishes before cascading to the session.

When an RP exchanges a code at the token endpoint, Ankole calls
`Attesto.AuthorizationCode.redeem/4` ahead of the issuance transaction, and
`CodeStore.take/1` atomically marks the code consumed. Both code exchange
(`Grants.exchange/2`) and token refresh (`Grants.refresh/2`) run inside
`Repo.transact_top_level/2`. If the Client, redirect URI, or PKCE verifier is
invalid—or if the grant has expired—the code remains consumed and cannot be
restored. During issuance, Ankole holds `FOR SHARE` on the Human row and
verifies the Client, granted scopes, OIDC session, active Human status, current
`PodLoginPolicy` compliance (`PodLoginPolicy.authentication_allowed?/3`), and
AI Gateway policy.

Upon passing those checks, Ankole signs a 30-minute RS256 `at+jwt` access token
containing the target audiences, `client_id`, `sid`, `sub`, `subject_type`, and
`token_use`. `Attesto.IDToken.mint/4` signs the ID token once with `sid`, any
requested `nonce`, `at_hash`, and the code's recorded `auth_time` (when known), while
`Ankole.OIDC.Claims.project/3` projects scope-gated profile claims across both
ID tokens and UserInfo.

Once the full token response is assembled, Attesto finalizes the authorization
code, recording any issued refresh family and the replay-retention deadline.
This `finalized` marker separates completed grants from codes whose downstream
token issuance failed: replaying a finalized code revokes its OIDC session and
refresh family, whereas a failed issuance leaves the code spent without planting
a false replay trigger.

## Refresh storage and rotation

`Attesto.RefreshToken` governs refresh issuance, scope narrowing, token
rotation, retry recovery, and reuse detection, backed by PostgreSQL transactions
in `Ankole.OIDC.RefreshStore`. Both `RefreshStore.rotate/2` and
`RefreshStore.revoke_family/1` open `Repo.transact_top_level/2` (with rotation
invoking the same family-revocation routine in-transaction when needed). Because
a family's initial refresh token is inserted inside the authorization-code
exchange transaction, calling `RefreshStore.insert/1` outside a transaction
raises `TransactionRequired`; code-store callbacks themselves are single
statements.
Each refresh token carries the authentication time from its authorization code
in its immutable protocol context.

In PostgreSQL, the refresh-family row holds the absolute 30-day deadline and a
sticky revocation timestamp, while each token row stores its SHA-256 digest,
`family_id`, `generation`, expiry, and consumption state. Native relational
columns hold the subject, Client, Session, and scope; a JSON context map holds
the remaining protocol fields, and `RefreshStore` merges both on read. A unique
constraint on `(family_id, generation)` guarantees at most one successor per
generation.

To prevent deadlocks with concurrent deletions or Human offboarding, issuance,
rotation, and family revocation all acquire parent locks through
`Ankole.OIDC.Sessions` in strict foreign-key order: first `FOR KEY SHARE` on
the tenant, subject Principal (in that tenant, matching the Session's
tenant-scoped foreign keys), and Client; next `FOR UPDATE` on the OIDC Session
(which also serializes revocation across all of the Session's refresh
families); and finally locks on the refresh family and parent token. Before
marking the parent consumed and inserting the child in one transaction,
rotation verifies that the family is unrevoked, the parent is unexpired, and
the child contract holds. Any integrity conflict revokes the family, and a
revoked family rejects all future insertions and rotations.

To tolerate transient network drops, an identical refresh retry within 10
seconds recovers the exact successor token as long as that successor remains
the unconsumed leaf. PostgreSQL stores this credential-equivalent retry bundle
under authenticated encryption bound to the parent token's digest. Once the
10-second window passes, reads omit the expired retry bundle from the returned
struct without mutating disk, and background cleanup later erases the
ciphertext while keeping the consumed token row as a replay tombstone.
Presenting a consumed refresh token outside that grace window—or after its
successor has already rotated—revokes both the refresh family and its OIDC
session.

Before rotating a token, `Grants.refresh/2` checks that the request retains
`openid` and satisfies the Client's scope policy; after rotation, it rechecks
the OIDC session, Human status, and AI Gateway policy, revoking the rotated
family if any check fails. Refresh responses return a new access token and
successor refresh token, without minting a new ID token.

## Client authentication, UserInfo, and introspection

Public Clients authenticate by sending `client_id` alone, while confidential
Clients must use `client_secret_basic` (Ankole rejects form-body secrets and
client assertions). Client authentication combines `Plug.BasicAuth`, form
decoding, and a constant-time secret comparison; if a request carries an
`Authorization` header with bad credentials or an unsupported scheme, Ankole
replies with a `Basic` challenge.

The UserInfo endpoint accepts an access token via either a case-insensitive
`Bearer` header or a `POST` form `access_token` field. Ankole's shared
access-token verifier checks the token signature, live Client, and OIDC session
(including active Human status and `PodLoginPolicy` compliance) in one pass and
hands the verified context to UserInfo, which checks `Origin` and projects the
Human's current profile without re-verifying the token or session.

Token introspection requires an authenticated confidential Client. For access
tokens, Ankole runs the same shared verifier; for refresh tokens, it looks up
an unconsumed, unexpired token in a live family and checks its OIDC session
against current Human status and `PodLoginPolicy`. If a Client attempts to
introspect a token belonging to another Client, Ankole returns `active: false`.

## Keys, issuer, and rolling deployment

`Ankole.OIDC.SigningKeyRecord` stores the site's encrypted PKCS#1 private key,
public JWK, and key ID in a site-scoped row that persists across deployments.
At boot, if no record exists, Ankole generates and stores a key; if a record
exists, `SigningKey` verifies that it decrypts cleanly and matches its stored
public JWK before publishing an immutable runtime cache, halting startup rather
than replacing a corrupted or mismatched key.

`Ankole.OIDC.Keystore` exposes that cached key to Attesto, which computes JWK
representations, the RFC 7638 thumbprint key ID, the JWKS document, and base
discovery metadata. `Ankole.OIDC` layers Ankole's protocol policy over that
metadata and serves HTTP discovery requests—explicitly stripping DPoP from the
discovery projection because Attesto advertises DPoP unconditionally.

`Ankole.TokenSigning` reads the OIDC issuer URL from application configuration.
Production builds require an `https://` issuer validated through
`Attesto.Config.new/1`. Only development and test builds permit an `http://`
issuer (provided it has a valid host and no userinfo, query, or fragment), and
that local path still validates the Principal kind and keystore callbacks
before constructing the config.

## Logout and cleanup

For RP-initiated logout, `Attesto.EndSession.parse/2` verifies `id_token_hint`
values—even after token expiry—and binds any explicit `client_id` to the hint's
audience, while Ankole checks the OIDC session and permitted recent-logout
window. Ankole requires interactive browser confirmation before ending the
browser login, after which `Attesto.EndSession.confirm_redirect/2` validates
the exact registered post-logout redirect URI and appends `state`.

Confirming an RP logout (`Logout.confirm/2`) terminates the browser session via
`BrowserSessions.logout_in_tx/2` and marks the confirmation request consumed in
a single `Repo.transact_top_level/2` transaction. The confirmation action
accepts only an unconsumed request and never alters its bound browser ID or
revision.

For Back-Channel Logout, Ankole queues durable delivery rows in PostgreSQL
tracking attempt counts, exponential backoff, and deadlines, while Attesto
signs each `logout+jwt` with `sub`, `sid`, and the logout event claim. Both
worker claims (`Logout.claim/1`) and operator retries (`Logout.retry/1`) run in
`Repo.transact_top_level/2`; the outbound HTTP `POST` executes outside the
transaction after the claim commits, and its outcome writes back in one atomic
update.

Background cleanup uses atomic resource deletes. Session delete statements
evaluate retention predicates inline so Ankole removes an OIDC session only
when no active authorization codes, refresh tokens, or undelivered logout rows
still reference it. Likewise, credential cleanup retains finalized code rows
until their replay-detection deadlines pass, deletes expired refresh rows after
their retry windows close, redacts expired successor ciphertexts, and prunes
eligible session and browser state. Every query or mutation on a tenant-scoped
table binds an explicit tenant context through `Ankole.Repo`.
