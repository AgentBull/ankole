# Browser Sessions

Ankole gives one browser a consistent Human identity while keeping Console
permission separate from OIDC authentication. PostgreSQL owns authentication
state and the generation used to reject obsolete callbacks and cookies.

## Ownership

`Ankole.BrowserSessions` owns `browser_sessions` and
`browser_login_transactions` in PostgreSQL. `AnkoleWeb.Session` provides the web boundary.
IdentityProviders verifies credentials. Principals owns identity and account
revocation. AuthZ decides Console access. OIDC owns authorization credentials,
Client policy, RP session associations, and logout notification delivery.

Keep the current Principal UID and matching rules in [Principal](Principal.md).
Account switching selects a verified identity; it does not introduce another
contact-matching or account-merging rule. A provider link on a Principal does
not prove that a particular login used that provider.

## Durable Session State

Authentication and login continuations use a durable browser session record. The cookie carries an opaque reference
and generation under the existing AEAD protection. Use the owning context's
identifier convention. Do not add a second cookie cryptography mechanism.

The browser record contains its generation, expiry, revocation state, and the
Console and OAuth authentication contexts. Each context contains Principal UID,
Human revocation generation, verified provider ID, external identity reference,
actual authentication time, and expiry. A browser session lives for 24 hours
and a login transaction for 10 minutes. Secrets and provider tokens remain in
their existing encrypted owner storage.

A browser can have Console and OAuth contexts for the same Principal. A Console
context is valid only while that Human is an active administrator. OAuth login
does not create a Console context, even when the person has administrator rights.
Console SSO can create an OAuth context only when the verified source and
authentication age meet current Client policy. Copy the authentication event;
do not set a new authentication time when reusing it.

Read current session state and Human revocation state at authenticated entry
points. An unavailable database cannot be treated as an active session.
Browser revocation affects one browser. The generation in
[Human Offboarding](HumanOffboarding.md) invalidates credentials on every device.
These are different scopes and must not share one revocation counter.

## Login Transactions and Concurrency

Store each login transaction under the browser reference and expected generation.
Its purpose distinguishes Console, OAuth, and forced password change. Bootstrap
state stays separate and cannot complete a normal login. An OAuth transaction
also binds the complete validated request and its provider selection, as defined
in [OIDC Server](OIDCServer.md#authentication-requests).

Use an opaque transaction ID rather than a single pending authorization slot.
On callback, verify state, purpose, provider, expiry, and expected generation.
Credential verification alone does not authorize a session write: completion
must lock the browser record and compare its current generation before commit.
Consume the transaction once, check current Human access, and store the verified
authentication context in that transaction. Replays and stale callbacks fail.

Successful explicit authentication advances the browser generation and ends
other pending login transactions. The first valid completion wins when several
flows started under the same generation. Preserve only the successful flow's
bound OAuth continuation and consume it once when issuing its code. Another tab
can start a new flow after reading current state; it cannot overwrite the
winner with an old callback. A failed or cancelled fresh-authentication request
does not resume authorization using a previous identity.

Commit generation checks, transaction consumption, and authentication changes
together. Keep browser and Principal lock order consistent across login,
logout, and account disablement. Network calls to an identity provider run
outside the database lock; completion rechecks state after the network result.

An HTTP response can arrive after a newer response. Its old cookie reference or
generation must not restore old authentication. Reject it on the next read;
requiring authentication again is an acceptable recovery. The system does not
promise to control browser response ordering.

## Identity Changes

On successful explicit Console authentication, end any conflicting OAuth
context and its browser-bound authorization state before storing the new
Console context. On successful explicit OAuth authentication, end a conflicting
Console context before storing OAuth authentication. Do not grant the new Human
administrator access as a side effect.

Contexts for the same Principal may remain, but each keeps its own verified
source and authentication time. Each use must still satisfy its permission and
Client policy. Never infer freshness from another context's token issue time.
Ending an old OAuth context uses OIDC's existing session termination operation,
including notifications for its registered RP sessions.

## Authentication Freshness

Local password verification establishes a new authentication event. An external
provider adapter must return evidence sufficient for the requested authentication
age and interaction. Forward supported reauthentication options through the real
adapter and validate the result. Profile retrieval and authorization-code
exchange alone do not prove a new upstream authentication event.

The local password adapter establishes `auth_time` when it verifies the password.
The Lark adapter supports ordinary login but cannot prove forced upstream
reauthentication. It is unavailable for `prompt=login`, `max_age`, or an essential
`auth_time` claim; those requests fail when no allowed provider can prove freshness.
An adapter that cannot establish the required freshness returns an explicit
authentication failure for that request. It must not fabricate `auth_time` from
the callback time. Provider SSO may avoid another QR scan; the interface must
not promise a fresh scan when the provider cannot enforce one. Ordinary login
can use the provider's existing supported authentication contract.

## Current-Browser Logout

Console logout and confirmed RP logout call one session-ending operation. Lock
the current browser generation, end both authentication contexts, invalidate
pending normal login, OAuth authorization, and password-change transactions,
and persist OIDC session-termination work in the same transaction. Expire the
browser cookie only after that commit. Setup state remains isolated and cannot
serve as a fallback login.

A stale logout confirmation cannot end a newer authentication generation.
Show that state changed and require a fresh confirmation. A repeated request
for the same ended session is safe. A delayed callback cannot recreate an ended
generation, including after process restart or on another control-plane node.

This operation does not disable the Human, end another device, or log out the
upstream provider. OIDC owns the treatment of online and offline grants and
notifications to associated RP sessions. See
[RP-Initiated Logout](OIDCServer.md#rp-initiated-logout).

## Interface and Migration

Show the verified display name and login source on authentication and logout
confirmation pages. Use a stable, recognizable account identifier when a name
is absent. Explain an identity conflict or expired transaction and provide a
new login action. Display labels never select the Principal or grant permissions.

On deployment, reject legacy authentication contexts and pending transactions
that lack durable generation and authentication evidence. Require fresh login
in the same browser without asking users to clear cookies. Keep Principal data,
identity links, permissions, and work history. Do not convert an old `issued_at`
into a new authentication event. Normal SSO resumes after fresh authentication.

Do not roll back to cookie-only authentication while issuing credentials that
depend on durable revocation. Preserve session termination and pending logout
delivery records through migration and rollback. Expired records may be removed
only when their dependent credentials and pending delivery no longer need them.

## Expired State Cleanup

The existing OIDC credential cleanup job runs once per hour. It removes
expired OIDC logout requests and eligible RP associations before it calls
`BrowserSessions.cleanup_expired/1`. Browser Sessions removes expired login
transactions, then expired browser records with no remaining RP associations.
Foreign keys retain the dependent records' ownership. See the
[OIDC cleanup rules](OIDCServer.md#expired-state-cleanup) for credential,
recent-session, and delivery retention.
