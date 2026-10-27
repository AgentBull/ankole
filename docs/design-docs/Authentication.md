# Authentication

Ankole verifies a person's control of a login credential. Each Pod owns its
Human Principals, memberships, enterprise identities, and personal credential
bindings. A verified site credential selects the Pods that bind that credential.
The Pod Principal is the subject for authorization and work attribution.

## Login sources and identity

Email OTP is a site source named `email_otp`. A person can verify one email and
select all available Pods that bind it. Enterprise SSO is a tenant source. Its
outbound OIDC state names one tenant and provider when the redirect starts, and
its proof gives access to that tenant.

`principal_site_credentials` stores a personal credential for one Human in one
Pod. The unique tenant/provider/identifier key protects ownership. Account
credentials permit one binding per Principal and provider. WebAuthn credentials
permit more than one key. The provider/identifier index supports site discovery.
`kind` distinguishes OTP, OIDC, and WebAuthn credential records. Pure secondary
factors, such as TOTP, belong to their factor owner.

`principal_external_identities` stores enterprise provider subjects. Lark uses
its immutable `user_id`, `union_id`, and `open_id` candidates. Directory contact
email addresses use the `email` namespace. Both the enterprise and member email
can identify a pending Human. Contact fields describe a person; a verified site
credential gives permission to use a login method.

## Verification ceremonies

`Ankole.Authn` declares strategies on the SiteCredential and ExternalIdentity
resources through Spark. Its transformer creates typed generic actions for
request, verification, authorization, and callback phases. `Info` dispatches to
those Ash actions. The Strategy protocol supplies the strategy name, scope,
provider, and supported phases. The resource verifiers check the credential
contract. Lifecycle add-ons compose member binding, invitation, and release
operations. Web resources own HTTP requests and cookie effects. The credential
resource declares the OTP sender as `otp(:email_otp, sender: Ankole.Authn.Mailer)`.
Enterprise code exchange and token verification run before the database
transaction. Identity admission, invitation acceptance, and browser completion
then commit together in one transaction.

The OTP strategy reserves a challenge digest in a transaction. It sends the
code through its Sender after that transaction commits. It activates the
challenge only when the stored digest still matches the reservation. Successful
activation invalidates earlier unused codes for the same browser group, tenant,
purpose, and normalized target email. Codes for different email addresses stay
independent. Delivery failure discards the new reservation and leaves the
previous code usable.

`authn_challenges` stores the browser group, optional tenant and Principal,
strategy, purpose, factor stage, target, secret digest, attempt count, limit,
start time, expiry, verification time, and ceremony context (including login
purpose, mode, return path, and optional invitation, reauthentication, or OIDC
authorization request reference). OIDC requests and pinned reauthentication
also supply their `started_revision`. The default limit is five attempts.
Verification locks the browser before the challenge.
A rejected code commits its attempt. A correct code commits consumption before
the membership, binding, or setup transaction begins. That transaction locks the
browser first and applies the current domain rules. A business rejection leaves
the code consumed. A consumed or exhausted ceremony clears its secret and expiry.
Challenge deletion runs through the periodic expunger.

An ordinary first-party OTP has its own lifetime, independent of an existing
login session. Browser logout ends established authentications. A valid unused
ordinary code can establish a new authentication after logout, including for
the same account. Verification checks the code's expiry, attempt budget,
browser binding, and current access policy. An OTP for an OIDC authorization
request or pinned reauthentication also requires that context to remain valid.

The code replacement rule follows the latest-code behavior described by
[Auth0 email OTP](https://auth0.com/docs/authenticate/passwordless/authentication-methods/email-otp)
and [Okta email OTP](https://support.okta.com/help/s/article/Is-there-a-difference-between-the-onetime-verification-code-validity-for-Email-MFA-and-SMS?language=en_US).
[Okta factor operations](https://developer.okta.com/okta-sdk-java/apidocs/com/okta/sdk/resource/api/UserFactorApi.html)
identify the user and factor. Ankole applies replacement within the scope above.

A supervised ETS limiter handles send and failure windows. It uses digested
keys, a capacity limit, and periodic cleanup. Its GenServer checks every window
before it increments the counters together. Read-only checks use ETS directly.
At capacity, the owner removes expired entries; valid populated keys and
verification checks remain usable. PostgreSQL owns each challenge's attempt
budget. A node restart can clear the rate windows and preserve the challenge
budget.

The Auth HTML shell supplies public feature decisions in its
`ankole-features` meta element. Site login uses the site context; Pod login
uses its tenant context. The official OpenFeature provider loads this
snapshot before the first render. A backend consumer evaluates its feature
at its own operation boundary.

The Auth HTML shell includes the target tenant's display name for Pod and OAuth
logins. The SaaS login page uses it to identify the destination before the
person signs in.

A build can wrap the Auth SPA with `AuthAppSlots.emailOtpChallenge` and run
an outer request Plug before the core OTP challenge endpoint. The slot's
attempt state supplies request headers for sending and resending a code.
See [Webapp entries and slots](Plugins.md#webapp-entries-and-slots).

## Email transport and setup

`Ankole.Authn.Mailer` sends verification codes and Pod invitations through Swoosh.
Compile-time MJML templates (`MjmlEEx` with `Mjml`) render multipart HTML and
plain-text messages. Message text uses the request `Accept-Language` header, the
target tenant's default locale, or the site default locale. Agent email has a
separate owner.

The global encrypted `authn.email.mail` setting holds the SMTP server, port,
sender, optional username and password, TLS mode, and optional CA file. SMTP uses
certificate and host verification. The configuration validates SMTP field types,
port range, and sender address when saved. `nil` means unconfigured.
Email OTP is available when `authn.email.mail` is configured or when the local
development adapter (`Swoosh.Adapters.Local`) is active. Local development stores
delivered messages in memory and serves the mailbox preview at `/dev/mailbox`.

First-run setup supports enterprise SSO or SMTP email verification. SSO setup completes
when a real provider callback verifies the first administrator. SMTP setup
sends a real six-digit code with the proposed settings. Verification commits
the encrypted mail settings, setup completion, Human, credential, administrator
groups, and browser proof. The first administrator receives both `siteadmin`
and the default Pod's `pod_admin` membership.

The SSO form supplies the callback URL from the provider's default configuration
ID. An optional control changes this ID. SMTP verification has separate controls
to resend the code and edit mail settings. A resend keeps the verification step
open. A successful delivery replaces the challenge and clears the entered code;
a failed delivery keeps the current challenge and code with the error message.

A server operator can repair SMTP configuration with:

```sh
mix ankole.authn.mail.put /secure/path/mail.json
```

The task accepts `-` for standard input. The release operation is
`Ankole.Release.put_authn_mail(json)`. Treat the input as a secret.

## Pod selection and invitations

A proved site credential lists the person's active and pending Pods; when zero
memberships exist, the browser session remains valid with an empty Pod list so
the person can accept an invitation (or use an extension-provided workspace
onboarding flow).

A verified email or phone can discover a unique active pending Human from
contact records. Directed email invitations also appear as pending Pods. A
click binds the proof to that member. A fresh proof at a Pod's own entry can
claim its pending member during login. The current login policy applies to
each claim.

`pod_invitations` stores token and code digests, target tenant, role, optional
email, expiry, quota, use count, creator, and revocation time. The acceptance
transaction locks the invitation, checks the current policy and quota, creates
or selects the Human, binds the verified credential, and consumes a use for a new
member. A member who already belongs to the Pod keeps their role and does not
consume another new-member use. Enterprise identity admission and invitation
acceptance commit in one transaction within the target tenant.
If activation of a pending Pod requires another verification or enterprise SSO,
`/api/v2/browser/authentications/current` seals a 10-minute `browser.invitation`
ticket for `/sessions/new`, and the selected OTP challenge or outbound OIDC
state accepts the invitation on successful completion.
Email invitations require configured SMTP before creation. Delivery runs outside
the creation transaction; a failed delivery revokes the invitation.

The shared browser API serves invitation preview, login, and acceptance at
`/api/v2/browser/invitations`. `/join/:token` displays the target Pod, role, and
available verification methods. Pod administrators manage invitations at
`/api/v2/pod/admin`.

## Login policy and member control

`principals.pod_login_policy` controls email OTP, member credential changes,
email domain admission, member SSO requirements, and invitation links.
`pod.allow_external_guests` controls Guest access. Policies apply during login,
proof reuse, Pod switching, and OIDC token validation. A member SSO requirement
permits enterprise proofs and can permit Guest email admission.

A policy change that removes the current administrator's permitted login path
is rejected. The administrator needs a binding to an enabled allowed source.
Pod administrators use Pod settings for the profile, members, invitations, and
enterprise provider configuration. The platform application owner prevents one
enterprise application from binding to different tenants.

Provider creation and editing use separate operations. Creation rejects an
existing ID; editing requires an existing ID. New connection forms suggest an
unused ID. These checks apply to both Console and Pod settings.

Personal account settings use `/api/v2/pod/me`. A member can update their display
name there. Administrators must supply an email when they create a pending member,
so the member can claim it with a verified login. Credential changes and voluntary
Pod exit require recent browser verification as defined in
[Browser Sessions](BrowserSessions.md#freshness-and-logout). The persisted
`authenticated_at` timestamp records local ceremony completion; the Actor exposes
it as epoch seconds. The provider's signed `auth_time` remains its original value,
including `nil` when unknown. `challenge_started_at` is the release watermark for
recycled identifiers, not the completion time used for recent verification.
Reauthentication fixes the current document's Pod and Human, including when
another browser tab has selected a different member or the user selects another
login source. Binding or replacing an email also requires verification of the
new address. The current Pod policy applies. A successful email change returns
a new browser proof for the same Pod member. When the profile email matches the
replaced credential, the same transaction updates that email. An independent
directory contact stays under its directory owner. The current document updates its
proof and CSRF token. Other Pod identities keep their independent bindings.
Unbinding the last permitted login method is rejected. Disabling a provider
cannot remove the last administrator's permitted login path. A directory-managed
member must use organization offboarding. An unmanaged member can leave the Pod,
subject to the last active administrator check.

## Suspension and departure

Suspension revokes access and work, and preserves personal credentials and
contact ownership. Restoration permits those bindings to work again.
Offboarding releases every personal credential and recyclable contact in that
Pod, including email aliases and phone ownership. Immutable enterprise subject
IDs, work attribution, and audit history stay with the departed Principal.

An access restriction records its `suspended` or `offboarded` disposition.
The disposition is part of its identity. An offboarding operation releases
contacts even when suspension already disabled the Principal. A healthy
directory observation cannot reattach released contact fields during the same
local offboarding cycle.

The offboarding audit stores released identifier keys. A pending claim compares
its ceremony start time with the latest release for those keys. An older browser
proof must verify control again. A replacement employee receives a new Principal.
Each Pod owns this release independently. A person should use a personal email
for a private Pod that they intend to keep, because an employer can reassign a
work email.
