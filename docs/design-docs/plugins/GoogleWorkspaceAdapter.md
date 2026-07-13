# Google Workspace Adapter

The Google Workspace plugin connects one Workspace organization to Ankole
through a single host-owned contract: Google login and directory
synchronization through Principals. It is the first identity-only plugin —
there is no chat adapter half — and it exists in two independently usable
parts: OIDC sign-in with Google accounts, and Admin SDK directory sync through
a service account. Either part can run without the other.

The plugin is trusted first-party Elixir code running in the control plane.
Agent Computer never talks to Google directly.

For the shared boundaries, see `docs/design-docs/Plugins.md` and
`docs/design-docs/Principal.md`. The cross-provider email join this plugin
relies on is host behavior documented in `Principal.md`.

## Stable Names

The public names are:

- plugin id: `google-workspace-adapter`;
- identity-provider adapter id: `google-workspace`;
- identity configuration pattern:
  `principals.identity_providers.google-workspace.<id>`;
- default provider id / platform-subject namespace: `google-workspace-main`;
- provider library: `libs/google_openapi` (module `GoogleOpenAPI`);
- kernel signing helper: `Ankole.Kernel.jwt_sign_pem/3`.

Subjects are keyed by Google's stable account id: directory sync uses the
Directory API user `id`, and login uses the OIDC `sub` claim, which Google
documents as the same global, never-reused account identifier (it is not
pairwise per app). The design does not depend on that equality: both carry the
user's email, so even a divergent pair would converge on one Principal through
the host email join.

## Plugin Declaration

One `principals.identity_provider` declaration with capabilities
`oidc_authorization`, `oidc_code_exchange`, and `directory_full_sync`.

`directory_realtime_sync` is deliberately not declared. Google's viable
realtime channel is Reports API `activities.watch` (admin audit events cover
user, group, and membership changes), but its channels expire after at most
six hours and its receiving domain must pass Google domain-ownership
verification. That renewal machinery is out of scope for this phase; directory
changes converge through the periodic full sync. The host webhook ingress
surface (`/webhooks/v1/...`) already exists when a later phase adds the watch
channel.

There are no supervised children and no connection reconciler.

## Configuration

All values live under the encrypted pattern
`principals.identity_providers.google-workspace.<id>`:

- `clientID`, `clientSecret` — Google Cloud OAuth client; required when
  `oidc.enabled`.
- `oidc.enabled` (default true), `oidc.scopes` (default
  `openid email profile`).
- `oidc.allowedDomains` — required non-empty domain list when `oidc.enabled`.
  Google has no Entra-style tenant isolation: without this gate any Google
  account could sign in and mint a Principal. Multi-domain organizations list
  every domain (including secondary domains) here.
- `serviceAccountKey` — the service account's JSON key, pasted verbatim;
  required when `sync.contacts`. Validation checks it parses and carries
  `client_email`, a PEM `private_key`, and `private_key_id`.
- `adminEmail` — the administrator the service account impersonates through
  domain-wide delegation; required when `sync.contacts`.
- `sync.contacts` (default true), `sync.pageSize` (default 500; the library
  additionally caps groups/members pages at the API maximum of 200),
  `sync.includeSuspended` (default false).
- `authBaseURL`, `tokenBaseURL`, `apiBaseURL`, `userinfoBaseURL` — advanced
  local-compatibility overrides used by tests.

## Provider Library

`libs/google_openapi` is a thin Req-based client mirroring the sibling
provider libraries: plain HTTP semantics, `nextPageToken` streaming
pagination, and rate limiting normalized to `:rate_limited` (429 with
`Retry-After`, plus 403 bodies whose error reason is a Google rate-limit or
quota reason).

The library holds no key material and does no crypto. The service-account
grant works through an `assertion_signer` closure on the client: `Auth`
builds the JWT bearer grant claims (`iss` = service account, `sub` =
delegated admin, `aud` = token endpoint, one-hour lifetime), the closure —
wired by the plugin — signs them with `Ankole.Kernel.jwt_sign_pem/3` (RS256,
`kid` = the key's `private_key_id`), and `Auth` exchanges the assertion for a
bearer token cached in ETS per `{service account, subject, scope}` with a
sixty-second refresh margin.

## Identity and Directory

Login follows the sibling adapters' server-side pattern: exchange the
authorization code, then read authoritative claims from the OpenID userinfo
endpoint; the `id_token` is never parsed locally. Before any Principal write,
the login gate requires `email_verified`, a present `hd` claim, and both the
`hd` claim and the email domain to be in `oidc.allowedDomains`. The authorize
URL passes `hd` as an account-picker hint only when exactly one domain is
allowed; the hint is user experience, the gate is the enforcement.

Directory sync authenticates with the service account and mirrors the
groups-then-users shape of the sibling adapters:

- `groups.list(customer=my_customer)` projects each Google group as an AuthZ
  directory group (`external_kind: :directory_department`, metadata kind
  `google_group`, group name
  `<provider_id>:google_group:<lowercased group id>`).
- `members.list` per group keeps direct `USER` members only. Nested groups
  are not expanded, matching the flat one-group-equals-direct-members
  projection of the other providers.
- `users.list(customer=my_customer)` upserts each user as a platform subject
  (`external_id` = directory user id) with display name, email
  (`primaryEmail`), job title (first `organizations[].title`), and E.164
  mobile (first `phones[]` entry of type `mobile`), then replaces the user's
  directory group memberships. Suspended and archived users are skipped
  unless `sync.includeSuspended`.

Organizational units are recorded as `org_unit_path` subject metadata only;
they do not become groups. Avatars are not synced
(`thumbnailPhotoUrl` requires authenticated fetches and has no public URL).

## Cross-Provider Identity Join (Slack + Google Workspace)

An organization that chats in Slack and manages identity in Google Workspace
gets one Principal per human, so Google directory groups govern the same
Principal that authors Slack messages. The join is host behavior in
`Principals.upsert_platform_subject_human` (see `Principal.md`): human email
is unique installation-wide, and a first-seen subject whose email already
belongs to a Principal binds to that Principal instead of creating a new one.

The operator recipe:

1. Configure the Slack chat binding as usual (namespace `slack-main`) and
   enable the Slack identity provider's directory sync with a bot token that
   has `users:read.email`. Slack chat projection alone stores no emails —
   the Slack directory sync is what puts emails on Slack-side Principals.
2. Run (or wait for) one Slack directory sync.
3. Configure the Google Workspace provider. Its sync and logins then claim
   the existing Slack Principals by email, attaching the Google subject to
   the same Principal.

Ordering matters for installations where Slack chat ran first: chat
projection creates email-less Principals, so if Google sync runs before the
Slack directory sync has attached emails, Google mints separate Principals,
and the later Slack email writes surface as
`principals.platform_subject.contact_conflict` warnings naming both uids.
Subjects are never re-pointed automatically; duplicate Principals that
predate the join are an operator cleanup. Pointing the Slack binding's
`platformSubjectNamespace` at `google-workspace-main` does not merge anything
— the external id shapes differ (`U…` versus the 21-digit Google id) — so do
not configure that.

## Operator Checklist

In the Google Cloud console (one project):

- enable the Admin SDK API;
- for login: create an OAuth client (web application), add
  `https://<host>/sessions/oidc/<provider_id>/callback` as an authorized
  redirect URI, and configure the OAuth consent screen for internal use;
- for directory sync: create a service account, create a JSON key, and note
  the key's client id.

In the Workspace Admin console:

- grant the service account domain-wide delegation (Security → API controls →
  Domain-wide delegation) for exactly the three read-only scopes
  `admin.directory.user.readonly`, `admin.directory.group.readonly`,
  `admin.directory.group.member.readonly`;
- pick an admin account for `adminEmail` with rights to read users and
  groups.

In Ankole, save the provider configuration; full sync runs on save, on the
periodic schedule, and on manual trigger.

## Ownership and Recovery

The plugin owns no durable state beyond what Principals and AuthZ already
persist: platform subjects, human profiles, directory groups, external group
bindings, and memberships. Bearer tokens live in a process-local ETS cache
whose loss only costs a token refetch. Everything else re-derives from a full
sync, which is the recovery action for any suspected drift.

## Deliberate Limits

- No chat adapter (Google Chat is out of scope).
- No realtime directory sync this phase; see Plugin Declaration for the
  designated future channel.
- No avatar sync, no nested-group expansion, no organizational units as
  groups.
- Mobile numbers are stored but never used as a join key.
- No automatic merge of duplicate Principals created before the email join
  existed; conflicts warn and are resolved by operators.
- No admin 3-legged OAuth fallback for directory sync: tokens bound to a
  human admin break when that human leaves, so domain-wide delegation is the
  only sync path.
- Email reuse (assigning a departed employee's address to a new hire)
  requires clearing the email on the old Principal first, as `Principal.md`
  documents.

## Verification

Covered by tests:

- kernel: `jwt_sign_pem` sign/verify round trip against `jwt_verify_jwk`,
  HMAC and bad-key rejection (`app/kernel`, Rust and Elixir suites);
- library: authorize URL, code exchange, userinfo, JWT bearer grant claims
  and caching, signer failure, pagination with rate-limit retry, 403 quota
  classification, page-size caps (`libs/google_openapi`);
- host: email join, contact-conflict drops, and mobile non-join semantics
  (`test/ankole/principals_test.exs`);
- plugin: declaration and booted-registry acceptance, configuration gating
  (allowed domains, per-half credentials, service-account key material),
  login-gate rejections, code exchange with domain enforcement, full sync
  with kernel-signed grant assertion and membership projection, and the
  Slack-to-Google email join
  (`test/ankole/plugins/google_workspace_adapter_test.exs`).

Not verified: an end-to-end smoke against a real Google Workspace tenant
(real OAuth consent, domain-wide delegation grant, and Admin SDK data). That
requires organization credentials this repository does not carry; run it
before first production use.
