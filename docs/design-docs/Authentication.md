# Authentication

Ankole authenticates users by verifying that a person controls a login
credential. Each Pod owns its own Human Principals, memberships, enterprise
identities, and personal credential bindings. Once a person verifies a site
credential, Ankole lists the Pods to which that credential is bound, and the
selected Pod's Principal serves as the subject for authorization and work
attribution.

## Login sources and identity

Ankole supports both site-level and tenant-level login sources. Email OTP is a
site source named `email_otp`: after verifying one email address, a person can
select any available Pod bound to that address. Enterprise SSO, by contrast, is
a tenant source: its outbound OIDC state names a single tenant and provider when
the redirect starts, and the resulting proof grants access only to that tenant.

`principal_site_credentials` stores personal credentials for one Human within
one Pod. A unique `(tenant, provider, identifier)` key protects credential
ownership, while an index on `(provider, identifier)` supports site-wide Pod
discovery. Within this table, `kind` distinguishes OTP, OIDC, and WebAuthn
credential records: account credentials allow one binding per Principal and
provider, whereas WebAuthn allows multiple keys. Pure secondary factors, such as
TOTP, live with their own factor owner rather than in
`principal_site_credentials`.

`principal_external_identities` stores subject identifiers from enterprise
identity providers. For example, Lark uses its immutable `user_id`, `union_id`,
and `open_id` candidates, while email addresses from directory contacts use the
`email` namespace. Either an enterprise email or a member email can match a
pending Human during onboarding; however, contact fields only describe a person,
whereas signing in requires a verified site credential.

## Verification ceremonies

`Ankole.Authn` declares authentication strategies on the `SiteCredential` and
`ExternalIdentity` Ash resources through Spark. At compile time, its transformer
generates typed generic actions for the request, verification, authorization,
and callback phases, while resource verifiers validate the credential contract;
at runtime, `Info` dispatches to those actions. Each implementation of the
`Strategy` protocol defines its strategy name, scope, provider, and supported
phases. Around these core actions, lifecycle add-ons compose member binding,
invitation, and release operations, while web resources handle HTTP requests and
cookies. For email OTP, the credential resource declares its sender with
`otp(:email_otp, sender: Ankole.Authn.Mailer)`. On enterprise SSO flows, code
exchange and token verification run outside the database transaction first, so
that identity admission, invitation acceptance, and browser session completion
can commit together in a single transaction afterward.

When starting an OTP ceremony, the OTP strategy first reserves a challenge in a
database transaction and sends the code through its `Sender` only after that
transaction commits. For login challenges, `Ankole.Authn` evaluates whether the
normalized target email is eligible to receive mail before generating a secret
digest:

- Tenant-targeted logins without an invitation (Pod sign-in, privileged-Pod
  sign-in for the Console, and OAuth authorization requests) deliver codes only
  when the email resolves to an existing Human in the target tenant, including
  disabled members and members whose Pod policy requires enterprise SSO so that
  submitting the code surfaces `account_disabled` or `login_policy_rejected`.
- Public link invitations deliver codes when the email matches an existing
  tenant Human or satisfies the Pod's login policy for the invited role and
  email domain, whereas directed email invitations deliver codes only when the
  submitted email matches the invitation's target address.
- Pinned reauthentications deliver codes only when the email resolves in the
  target tenant to the pinned Human Principal.
- Shared-host `site` logins without a target tenant deliver codes to any
  syntactically valid email address so users can verify an address before
  selecting, joining, or creating a Pod.

Once `Sender` delivery succeeds for an eligible target, `Ankole.Authn` activates
the challenge if the stored digest matches the reservation; activation
invalidates any earlier unused codes for the same browser group, tenant,
purpose, and normalized target email, while leaving codes for other email
addresses untouched. If delivery fails, `Ankole.Authn` discards the new
reservation so the previous code stays usable. When a login target is
ineligible, `Ankole.Authn` commits an unmatchable challenge (`secret_digest:
nil` with a normal expiry timestamp), invalidates earlier unused codes in the
same scope, and records the request against per-email and per-source send limits
while skipping `Sender` delivery and global `"smtp"` channel quota deduction;
the HTTP response returns the challenge ID and expiry so the sign-in UI presents
the standard code-sent state without disclosing account or administrator
membership.

`authn_challenges` tracks active and completed ceremonies. Each row stores the
browser group, optional tenant and Principal, strategy, purpose, factor stage,
target, secret digest, attempt count, attempt limit (five by default), start
time, expiry, verification time, and ceremony context—including the return path,
optional Console return path (`console_return_to`), optional target tenant ID
(`target_tenant_id`), and any optional reference to an invitation,
reauthentication, or OIDC authorization request (OIDC requests and pinned
reauthentications also record `started_revision`). During verification,
`Ankole.Authn` locks the browser record before locking the challenge. If the
submitted code is wrong, `Ankole.Authn` commits the incremented attempt count.
If the code is correct, it commits challenge consumption before starting the
membership, binding, or setup transaction, which again locks the browser first
and enforces current domain rules; if a domain rule rejects that transaction,
the code remains consumed. Whenever a ceremony is consumed or exhausts its
attempt limit, `Ankole.Authn` clears its secret digest and expiry, and a
periodic expunger deletes old challenge rows.

An ordinary first-party OTP has its own lifetime, independent of any existing
login session. Logging out of a browser ends established authentications, but a
person can still use a valid, unused ordinary code to establish a new
authentication after logout, even for the same account. When verifying a code,
`Ankole.Authn` checks its expiry, remaining attempt budget, browser binding, and
current access policy; if the OTP belongs to an OIDC authorization request or
pinned reauthentication, that parent context must also still be valid.

This code-replacement contract follows the latest-code behavior documented for
[Auth0 email OTP](https://auth0.com/docs/authenticate/passwordless/authentication-methods/email-otp)
and
[Okta email OTP](https://support.okta.com/help/s/article/Is-there-a-difference-between-the-onetime-verification-code-validity-for-Email-MFA-and-SMS?language=en_US),
along with the user-and-factor scoping in
[Okta factor operations](https://developer.okta.com/okta-sdk-java/apidocs/com/okta/sdk/resource/api/UserFactorApi.html),
applied within Ankole's browser-group, tenant, purpose, and target-email scope.

To bound request rates, a supervised ETS limiter tracks send and failure windows
using digested keys, a fixed capacity limit, and periodic cleanup. Read-only
checks read ETS directly, while write checks run through the limiter's
GenServer, which verifies every window before incrementing counters atomically.
When the table reaches capacity, the GenServer evicts expired entries while
keeping valid populated keys and verification checks working. Because PostgreSQL
owns each challenge's per-ceremony attempt budget, a node restart can clear the
in-memory rate windows without resetting any challenge's attempt count. When
`authn.email.send_limits` configures `site_resend_cooldown_seconds`,
`Ankole.Authn` enforces that per-email resend interval across unverified `site`
login challenges; verifying a `site` challenge clears the cooldown for that
challenge so the user can immediately start a reauthentication ceremony.

For browser rendering, the Auth HTML shell embeds public feature-flag decisions
in its `ankole-features` meta element—evaluating flags in the site context for
site login and in the tenant context for tenant-targeted login—and includes the
target tenant's display name when a target tenant is resolved so SaaS sign-in
pages can show the destination before login. The official OpenFeature provider loads this feature
snapshot before the first render, whereas backend consumers evaluate features at
their own operation boundaries. A build can also wrap the Auth SPA with
`AuthAppSlots.emailOtpChallenge` and run an outer request Plug ahead of the core
OTP challenge endpoint; that slot's attempt state supplies extra request headers
when sending or resending a code (see
[Webapp entries and slots](Plugins.md#webapp-entries-and-slots)).

## Email transport and setup

`Ankole.Authn.Mailer` delivers verification codes and Pod invitations through
Swoosh, rendering multipart HTML and plain-text emails from compile-time MJML
templates. `Ankole.Authn.Emails.Layout` compiles the shared layout and each
template with `Mjml`, then Elixir's EEx and `Phoenix.HTML.Engine` compile the
HTML renderer and escape dynamic values when sending a message. The mailer
selects the message locale from the request's `Accept-Language` header, falling
back to the target tenant's default locale and then `"en-US"`. Agent email uses
a separate subsystem and owner.

The global encrypted `authn.email.mail` setting stores the SMTP server, port,
sender address, optional username and password, TLS mode, and optional CA file
(`nil` means unconfigured). Outbound SMTP enforces certificate and hostname
verification, and saving the setting validates field types, port ranges, and the
sender address. Email OTP is available whenever `authn.email.mail` is configured
or when local development runs `Swoosh.Adapters.Local`, which keeps delivered
messages in memory and serves a mailbox preview at `/dev/mailbox`. When both
`/dev/mailbox` and `Swoosh.Adapters.Local` are active, SPA HTML shells include
`ankole-dev-mailbox` so code-sent prompts append a link to open `/dev/mailbox`.

The Console SMTP form can send a test through the current draft without saving
it or issuing a login challenge. The form reads only public transport fields and
password presence; omitting the password keeps the saved credential, while an
explicit replacement or empty password replaces it. Test acceptance reports
transport acceptance, not delivery to an inbox, and editing the draft invalidates
the displayed test result.

Email verification policies use global `authn.email.code_ttl_seconds`,
`authn.email.send_limits`, and `authn.email.failure_limits`. The send policy has
one `window_seconds` and independent `per_email`, `per_source`, and `per_channel`
maxima. The failure policy shares its own window across `per_email` and
`per_source`. Every field is a positive integer up to 86,400; no numeric ordering
between independent counters is required. The Console saves this task atomically.

First-run setup can establish the first administrator through either enterprise
SSO or SMTP email verification. On the SSO path, setup completes when a real
provider callback verifies the administrator; the form derives the callback URL
from the provider's default configuration ID, with an optional control to
override that ID. On the SMTP path, Ankole sends a live six-digit code using the
proposed mail settings, and verifying that code commits the encrypted mail
settings, setup completion, Human, credential, administrator groups, and browser
proof together. During SMTP verification, operators have separate controls to
resend the code or edit mail settings while keeping the verification step open:
a successful resend replaces the active challenge and clears the code input,
whereas a failed delivery preserves the current challenge and entered code
alongside the error message. Under either setup path, the first administrator
is added to both `siteadmin` and the default Pod's `pod_admin` group.

If SMTP settings break later, a server operator can repair them from the CLI:

```sh
mix ankole.authn.mail.put /secure/path/mail.json
```

The Mix task also accepts `-` to read from standard input, and releases expose
the same operation as `Ankole.Release.put_authn_mail(json)`. Treat the JSON
input as secret material.

## Pod selection and invitations

Once a person proves control of a site credential, Ankole lists their active and
pending Pods. If the person has zero memberships, the browser session remains
valid with an empty Pod list so they can accept an invitation or complete an
extension-provided workspace onboarding flow.

Ankole can match a verified email address or phone number to a unique active
pending Human from contact records, and it also surfaces directed email
invitations as pending Pods. Clicking a pending Pod in the switcher binds the
verified proof to that member; signing in with a fresh proof directly at a Pod's
own entry claims the pending member as well, subject to the Pod's current login
policy.

`pod_invitations` stores the token and code digests, target tenant, role,
optional email, expiry, quota, use count, creator, and revocation time. When a
person accepts an invitation, the acceptance transaction locks the invitation
row, checks current login policy and remaining quota, creates or selects the
Human, binds the verified credential, and consumes one quota unit if the Human
is a new member (existing Pod members keep their current role without consuming
a new-member slot). For enterprise logins, identity admission and invitation
acceptance commit in a single transaction inside the target tenant. If
activating a pending Pod requires an additional verification step or enterprise
SSO, `/api/v2/browser/authentications/current` seals a 10-minute
`browser.invitation` ticket and returns a redirect URL: when a Pod login policy
rejects email activation on an edition with a shared site sign-in host and the
target Pod has a single active OIDC provider, Ankole redirects directly to that
provider's OIDC authorization URL; otherwise it directs the browser to
`/sessions/new` on the edition's canonical sign-in host, and completing the
resulting OTP challenge or OIDC flow accepts the invitation. Creating an email
invitation requires configured SMTP; Ankole sends the email after the creation
transaction commits and revokes the invitation if delivery fails.

The shared browser API serves invitation preview, login, and acceptance under
`/api/v2/browser/invitations`, while `/join/:token` displays the target Pod,
offered role, and available verification methods (using `emailLoginURL` from the
preview response to route email verification to the edition's sign-in entry).
Pod administrators manage invitations under `/api/v2/pod/admin`.

Enterprise SSO workspace lookup returns the resolved `tenantID`. The browser
keeps `return_to` only when that ID matches the current login target; selecting
a different workspace or starting without a bound target uses the workspace root.
The browser may retain `prompt`, but it never copies an OAuth request or pinned
reauthentication/invitation ticket into workspace lookup results. OAuth login
uses its already resolved tenant providers without offering workspace lookup.

## Login policy and member control

Two configuration keys govern Pod access: `principals.pod_login_policy` controls
email OTP, member credential changes, allowed email domains, member SSO
requirements, and invitation links, while `pod.allow_external_guests` controls
Guest access. Ankole enforces both policies during login, proof reuse, Pod
switching, and OIDC token validation. Requiring SSO for members still accepts
enterprise proofs and can continue to allow Guest admission via email.

Pod administrators manage the Pod profile, members, invitations, and enterprise
identity providers in Pod settings, while the platform-application registry
prevents a single enterprise application from being bound to multiple tenants.
To prevent administrator lockout, Ankole rejects any policy change or provider
disablement that would remove the current or last administrator's permitted
login path; the administrator must retain a binding to an enabled, permitted
login source. Provider creation and provider editing are separate operations in
both the Console and Pod settings: creation rejects an existing provider ID
(and new connection forms suggest an unused ID), whereas editing requires an
existing ID.

Members manage their personal account settings at `/api/v2/pod/me`, including
their display name. When administrators create a pending member, they must
supply an email address so the member can claim the account with a verified
login. Changing credentials or voluntarily leaving a Pod requires recent browser
verification as defined in
[Browser Sessions](BrowserSessions.md#freshness-and-logout). For freshness
checks, Ankole persists `authenticated_at` when the local ceremony finishes and
exposes it on the Actor as epoch seconds; the upstream provider's signed
`auth_time` is preserved separately (`nil` when unknown), and
`challenge_started_at` serves only as the release watermark for recycled
identifiers rather than as the completion timestamp.

Starting a reauthentication pins the target Pod and Human for the current
browser document, even if another tab switches members or the user picks a
different login source. Binding or replacing an email address also requires
verifying the new address under the current Pod policy. When an email replacement
succeeds, Ankole returns a new browser proof for that Pod member, updates the
current document's proof and CSRF token, and—if the member's profile email
matched the replaced credential—updates the profile email in the same
transaction. Independent directory contacts remain owned by directory sync, and
credential bindings in other Pods stay independent. Ankole rejects unbinding a
member's last permitted login method. Finally, directory-managed members cannot
leave a Pod manually and must go through organization offboarding, whereas
unmanaged members can leave a Pod unless doing so would remove the last active
administrator.

## Suspension and departure

Suspending a member revokes their access and stops their active work while
preserving their personal credentials and contact ownership, so restoring the
member makes those bindings work again. Offboarding, by contrast, releases every
personal credential and recyclable contact in that Pod—including email aliases
and phone ownership—while keeping immutable enterprise subject IDs, work
attribution, and audit history attached to the departed Principal.

Each access restriction records its disposition (`suspended` or `offboarded`) as
part of its identity. Offboarding a Principal always releases recyclable
contacts, even if the Principal was already disabled by an earlier suspension,
and a healthy directory sync observation cannot reattach released contact fields
during the same local offboarding cycle.

To guard against recycled addresses and phone numbers, the offboarding audit log
records the released identifier keys. When a pending claim arrives for one of
those keys, Ankole compares the ceremony's `challenge_started_at` timestamp
against the latest release timestamp: if the browser proof started before the
release, the user must verify control of the identifier again, and a replacement
employee receives a brand-new Principal. Because each Pod manages credential
release independently—and an employer can reassign a work email address—users
should bind a personal email address to any private Pod that they intend to
keep.
