# Human Offboarding

Disabling a Human Principal immediately prevents that person from signing in or
starting new work in Ankole, and it stops future execution of their queued
tasks, cron schedules, and automation jobs. At the same time, Ankole preserves
the Principal UID, immutable enterprise subject IDs, completed work results, and
audit history. Suspension retains personal credentials and contact bindings,
whereas offboarding releases them within the affected tenant.

Ankole also exposes standard Back-Channel Logout and Token Introspection for
OIDC Clients. Because external OIDC Clients manage their own application
sessions and may process logout notifications asynchronously, local account
disablement commits immediately without waiting for external Clients.

An execution attempt that already passed its admission check before disablement
is allowed to finish: Ankole neither rechecks Human status before every tool
call nor interrupts an in-flight attempt mid-run. However, any retry, resumed
attempt, or subsequent scheduled run must pass a fresh admission check and is
therefore rejected.

This document specifies Human revocation, directory reconciliation, and
cross-subsystem work admission. Each linked subsystem document owns its own
storage schema and execution lifecycle.

## Scope and Ownership

Human offboarding operates across one Ankole site containing tenant-owned
Humans. Feishu and DingTalk supply automatic offboarding events and directory
syncs, while other identity providers use the same manual restriction contract
without automatic detection.

| Owner | Responsibility |
| --- | --- |
| Feishu and DingTalk adapters | Verify and interpret provider events, user state, and directory coverage. |
| IdentityProviders and Directory | Run complete syncs, reconcile provider membership, and submit offboarding facts. |
| Principals | Store Human access state, disable reasons, identity links, and the persistent revocation fact. |
| AuthZ | Decide permissions, protect manual administrator operations, and control restored permissions. |
| Console and OIDC authentication | Reject disabled Humans and revoked credentials at their own request boundaries. |
| OIDC | Provide standard logout notifications and Introspection, and own Client/session records and notification delivery. |
| Signals, Sessions, Schedule, Background Agent Jobs, Workflow, and Automation Jobs | Store the Human association of work, check it at execution admission, and stop future execution. |
| Agent Computer | Execute admitted attempts through the Worker contract. It does not own Human status or a separate permission list. |
| Console | Submit authorized operations and show account, sync, and affected-work results. |

The Elixir control plane stores all durable revocation state in PostgreSQL, and
each work subsystem owns its own lifecycle and public entry points. Oban runs
durable background cleanup jobs without owning the Human access decision itself,
and operator settings live under each owning subsystem's declared `AppConfigure`
keys.

Ankole does not implement an HR system, a second identity model, cross-enterprise
routing, automatic data deletion, or automated asset-transfer workflows during
offboarding.

## Tenant boundaries

Every Human Principal belongs to one home tenant. When a site administrator
authorizes work inside another tenant, that work still records the authenticated
administrator's `human_uid`. Across all six work tables, `human_uid` is stored
as a plain text reference without a database foreign key; if a referenced Human
is missing, admission treats the authorization as revoked, and deleting
the administrator's home tenant neither erases the recorded `human_uid` nor
requires the target tenant to clean up first.

Disabling a Human stops future work associated with that `human_uid` across
every tenant on the site. Tenant deletion follows the same revocation path and
finishes durable work cleanup before deleting the Human rows. Other tenants
retain their stopped work records together with their original authorization
metadata: operators in those tenants can explicitly reauthorize paused cron
rules from the work-review list, whereas terminal tasks and cancelled jobs must
be recreated through their owning subsystem. `WorkCleanup` records each
completed `access_version` sweep in Human access history, and tenant deletion
processes cleanup in bounded, retry-safe batches.

Suspending an entire tenant rejects new work admissions and marks Human OIDC
tokens inactive, while allowing already admitted attempts (and the Agent
credentials they use) to finish and recover across process restarts.

## Suspend and Offboard

Suspending a Human preserves the Human Principal, immutable provider subject
IDs, personal site credentials, and contact bindings so an administrator can
later restore the same account after reviewing identity and permissions.

Offboarding a Human preserves the departed Principal UID, immutable enterprise
subject IDs, historical work attribution, and audit records, while releasing
every unshared personal credential, email alias, contact email, and phone
binding in that tenant:

- If a new employee later joins with different provider subject IDs, Ankole
  creates a brand-new Human UID.
- Looking up a released email or phone never resolves to the departed Human.
- During an offboarding cycle, Ankole suppresses upstream contact writes for
  that account, and each Pod manages its own contact and credential bindings
  independently.

Whether a restriction is `suspended` or `offboarded` is part of its durable
identity. Consequently, an offboarding operation still releases credentials and
contact identifiers even if an earlier suspension already disabled the account,
recording the released identifier keys in the audit log. When a user later tries
to claim a recyclable contact identifier, Ankole verifies that the verification
ceremony started after the identifier's most recent release timestamp.

Every login method and work item belonging to a Human checks the same
`access_version`; see [Authentication](Authentication.md) for credential release
and fresh-claim rules.

## Browser authentication evidence

A single site authentication in a browser can back independent Pod access proofs
across multiple Pods, with each proof pinning the Human Principal UID and the
`access_version` verified at sign-in. Disabling a Human invalidates only that
Human's proofs while leaving the browser's other Pod identities usable, and any
login ceremony that finishes concurrently with disablement writes no proof for
the disabled Human.

Restoring a Human does not revive invalidated browser proofs: the user must
complete a fresh authentication ceremony (or explicitly connect through a second
current Pod proof) to verify the restored `access_version`. Navigating between
pages never copies a newer `access_version` onto an older proof. Because the
Principal row lock and transactional revocation check enforce this invariant
directly, no separate recovery clock is needed; see
[Browser Sessions](BrowserSessions.md#site-sources-and-human-recovery).

## Store Disable Reasons Separately from Sync Health

Principal access state uses only two values (`active` and `disabled`) while
storing the specific reason, source, operation or event ID, and timestamps on
separate restriction rows. Because multiple restrictions can apply to one Human
simultaneously, clearing one restriction never clears another.

| Observation | Required result |
| --- | --- |
| Confirmed departure or exit from the enterprise | Disable the Human with that reason. |
| Confirmed freeze or suspension | Disable the Human without deleting profile data. |
| Authorized manual disable | Disable the Human and retain the operator's reason. |
| Confirmed removal from the configured admission scope | Disable the Human with a scope-removal reason. |
| Absence from a complete, trusted admission directory | Disable after the complete-sync checks below; record directory removal, not departure. |
| Timeout, missing permission, failed page, or unknown coverage | Report a sync failure; do not infer departure. |
| Return to the directory, unfreeze, or return to employment | Make recovery eligible for review; do not restore access automatically. |

An identity provider's directory-read scope and Ankole's application-admission
scope are distinct settings: a narrowed read scope by itself proves neither
employee departure nor revoked Ankole access. Operators must explicitly configure
which verified provider scope governs admission.

## Stored Access and Directory State

PostgreSQL tracks Human revocation and directory reconciliation across five
tables:

- **`principals.access_version`** is the monotonic revocation generation for a
  Human; adding a restriction increments it and invalidates session proofs and
  work items that captured an earlier version.
- **`human_access_restrictions`** stores each active restriction independently,
  recording its `disposition` (`:suspended` or `:offboarded`) and any upstream
  recovery evidence. `:suspended` retains personal `principal_site_credentials`
  and contact bindings, whereas `:offboarded` releases unshared personal site
  credentials and tenant email or phone bindings.
- **`human_access_events`** appends immutable audit records for restrictions,
  `released_identifiers` watermarks, permission-review approvals, and cleanup
  sweeps, deduplicating repeated upstream deliveries via a unique
  `(source, operation_id, principal_uid)` key.
- **`identity_directory_events`** persists inbound provider webhook events
  before acknowledging delivery.
- **`identity_directory_states`** tracks the provider's latest revision, scope
  and snapshot fingerprints, known members, missing-member candidates, sync
  health, and operator review state. Editing provider settings or receiving a
  directory event increments this revision, so an in-flight sync that started on
  an older configuration or revision cannot commit missing-member removals.

Both `DirectoryState` and `DirectoryEvent` are Ash resources in
`IdentityProviders`. Event intake, event processing, operator review, sync
start, snapshot commit, and approval each run inside `Repo.transact_top_level/2`
and are exposed to the Console as generic actions. Locking the `DirectoryState`
row serializes event intake, operator reviews, and sync commits, and only its
owning actions may advance the revision or update sync health. Configuration
invalidation and failed-sync updates use atomic SQL predicates so neither a
failed sync nor a late collector can overwrite evidence from a newer revision,
and a concurrently reviewed or dismissed event cannot execute twice. Reviewer
attribution uses the Principal domain's tenant-qualified `ActorRef` codec.

For Lark directories, `sync.admissionScope = "none"` syncs user profiles without
disabling missing members, while `"contact"` enforces the provider contact scope
only after an operator approves the initial scope review. A full Lark sync walks
explicit users, departments, child departments, and paginated user groups, and
re-verifies the configured scope before committing. `sync.maximumRemovalPercent`
defaults to `20`: if a sync returns an empty directory or detects a scope
change, Ankole requires manual operator review even when the removal share falls
below `20%`. Clearing a provider restriction likewise requires recovery evidence
from a current, healthy directory snapshot.

## Detect Offboarding

The Feishu adapter distinguishes user deletions, user profile updates, and scope
changes, while the DingTalk adapter treats `user_leave_org` as a confirmed
departure event (see [DingTalk Adapter](plugins/DingTalkAdapter.md)). When an
adapter receives a trusted departure event, Ankole can disable a known Human
using only the stable provider subject ID without fetching a full profile.

Ankole resolves each inbound event against stored provider bindings and aliases.
If the subject is unknown or lacks required identifiers, Ankole records an
actionable review failure rather than creating a new active Human from a
departure event. Moreover, if a pending departure record exists for a provider
subject, an operator must resolve it before any subsequent login or directory
sync can provision that subject as a new Human.

Adapters acknowledge a webhook only after persisting either the completed
outcome or a durable pending-event row, making duplicate deliveries idempotent
and failed processing retryable. Whenever the provider supplies event-ordering
metadata, Ankole enforces it so a stale profile update cannot undo a
disablement; if event ordering is ambiguous, Ankole queries current provider
state and keeps the restriction active until an administrator authorizes
recovery.

Periodic and manual directory syncs (every 15 minutes by default) reconcile full
provider membership. Before a sync can automatically disable missing members,
all five conditions must hold:

1. The provider connection, API permissions, configured admission scope, and
   every paginated response are valid.
2. The fetched set covers the complete admission scope for that provider.
3. Member collection finishes completely before Ankole computes missing members.
4. Neither a concurrent webhook event nor a newer sync has advanced the provider
   revision since collection started.
5. An operator has already approved the initial identity and scope baseline
   before enabling automatic missing-member removal.

If a sync encounters a scope change, an unexplained empty directory, or a member
drop exceeding the configured removal threshold, Ankole halts automatic
missing-member disablement for that run and records a candidate list for
operator review instead. These sync safeguards never block an independent,
confirmed departure webhook. Conversely, while a partially failed sync may still
apply valid profile updates, Ankole never treats unseen users in an incomplete
sync as departed.

## Disable the Human

From the Console, an active administrator holding the Human-management
permission can disable a Human account. The server verifies both the caller's
permission and the target's state, returning the existing outcome on duplicate
requests while blocking manual self-disablement and blocking removal of the last
effective Human administrator.

Let `T0` denote the PostgreSQL commit timestamp of the disable transaction. In a
single transaction at `T0`, Ankole commits the `disabled` status, the bumped
`access_version` and restriction row, the immutable audit event, and the durable
Oban jobs that stop future work and notify OIDC Clients. Consequently, a
downstream cleanup or webhook failure can never roll back the disablement:
cleanup jobs retry safely after `T0`, while execution admission already rejects
the disabled Human immediately after `T0`.

As one deliberate exception to last-administrator protection, a confirmed
departure event from a trusted identity provider is allowed to disable even the
last effective Human administrator. Ankole keeps this exception strictly inside
the Principal/AuthZ boundary rather than inventing a half-disabled administrator
mode or leaving a departed employee active.

If a deployment is left with zero active administrators, an operator with shell
and database access to the control plane can grant administrator rights to an
independently verified, active Human by running:

```sh
mix ankole.admin.recover HUMAN_UID OPERATOR REASON --identity-verified --tenant SLUG
```

Run this command from the control-plane directory using the deployment's
configuration after provisioning and verifying the replacement Human through the
normal Principal and identity-provider flows. The target Human must already have
a login method permitted by the Pod's login policy, and the command refuses to
run whenever an active Pod administrator with a permitted login method already
exists. Omitting `--tenant` recovers site-administrator access in addition to
Pod-administrator access, recording both `OPERATOR` and `REASON` in the audit
log. Having zero active administrators never reopens public first-administrator
setup or automatically restores a departed account; see [AuthZ](AuthZ.md).

## Reject New Authentication and Requests

After `T0`, Ankole enforces Human revocation at every authentication and request
boundary:

| Entry | Result after disablement |
| --- | --- |
| Email OTP, personal credential login, enterprise SSO login, and session reuse | Reject a new authenticated session. |
| Console and OAuth browser sessions | Reject their next authenticated use on every device. |
| Authorization Code exchange and Refresh Token use | Reject credentials from the disabled or revoked authorization. |
| Console API | Reject the disabled Human's browser session. |
| UserInfo and Human AI Gateway requests | Reject the disabled Human, including an otherwise unexpired token. |
| Existing Human WebSocket | Reject a new protected request; an idle connection need not be closed. |
| Human signal, command, or approval input | Reject new action by the disabled Human. |

Console and OAuth sessions maintain separate authorization contexts under
[Browser Sessions](BrowserSessions.md), but both validate against the durable
Human `access_version` in PostgreSQL. Because revocation increments a durable
generation that survives process restarts and node failovers, restoring the
Human to `active` later never makes an old browser cookie, authorization code,
refresh token, or JWT valid again.

Requests and turns that already passed admission before `T0` may finish
streaming and running tools without rechecking Human status between tool calls,
while still enforcing normal token, Agent, resource, and turn-fence checks.
Ankole cannot roll back external side effects, including external requests sent
before `T0` that settle afterward.

## Notify OIDC Clients and Check Their Tokens

Ankole delivers Back-Channel Logout notifications and serves Token Introspection
according to [OIDC Server](OIDCServer.md#logout-and-cleanup), which specifies
wire payloads, Client registration, authentication, and retry behavior.

Unlike an ordinary browser logout, disabling a Human revokes every personal OIDC
authorization for that person, including `offline_access` refresh tokens. As
soon as the disable transaction commits at `T0`, Token Introspection, code
exchange, token refresh, `UserInfo`, and Ankole's own protected APIs all treat
those authorizations as inactive without waiting for Back-Channel Logout HTTP
deliveries.

Ankole queues a logout notification for every recorded OIDC Client session
affected by the disablement. Even if an administrator restores the Human before
a delayed notification is delivered, that notification still revokes the pre-`T0`
Client session, and neither a fresh login nor account restoration reactivates
revoked OIDC grants.

Each external OIDC Client remains responsible for terminating its own local
session and blocking downstream business actions; Ankole does not mutate
Client-local user tables or application roles. Because network retries and
Client-side token caching can delay external enforcement, there is no hard
end-to-end logout deadline across external apps. Instead, the Console surfaces
per-Client delivery status and token validity directly rather than treating
local disablement as proof that every external Client has revoked access.

## Associate Work with the Human

Human work authorization is distinct from Agent ownership and Session routing:
neither an Agent's creator, nor a task's title, nor a reply channel determines
which Human account must stay active for a piece of work to run.

For Human-derived work, the control plane derives the authorizing Human from
the authenticated source input and propagates that provenance across child
tasks, scheduled rules, automation triggers, retries, and crash recovery. Each
work subsystem stores this control-plane authorization fact in its own columns.
These records remain authoritative across restarts and source cleanup.

When a Human is disabled, all future work tied to that Human stops even if the
task invokes tools using an Agent or bot credential: an Agent token never
substitutes for an active Human authorizer. Conversely, independent service or
system work with no Human dependency continues under its own `service`
authorization. Site Console cron creation selects service authorization and
records the administrator separately in `created_by`. Disabling one sender in
a shared room rejects only that sender's pending inputs without disabling the
shared Agent or Session. If a work record lacks sufficient provenance
(`review_required`), Ankole blocks execution
until an operator classifies it rather than assuming independent service
authority.

Every durable work table stores three columns enforced by PostgreSQL check
constraints (`authorization_kind`, `human_uid`, and `human_access_version`):

- `human` requires both `human_uid` and a captured `human_access_version`.
- `service` requires an evidenced Agent or system execution source, including
  the Site Console cron creation action.
- `review_required` blocks execution until an operator classifies the record.

`Ankole.Principals.WorkAccess` validates these fields inside the owning
subsystem's transaction and implements explicit operator classification without
owning scheduling or Agent selection. `Ankole.Work.Provenance` declares the
three fields, each owner's reviewable states, its revocation callback, and the
`allow_global` read action `:work_across_tenants` (so cleanup can find a Human's
work across every tenant). `Ankole.Work.Owner` consumes those declarations to
drive the Console work-review registry and revocation dispatch, reading and
locking work rows through Ash. Execution subsystems call `WorkAccess` directly,
`Sessions` delivers wakeups, and `WorkCleanup` locks all candidate parent rows
before any callback locks child rows or Signals, running each callback inside
its row's tenant context within one transaction.

## Check Once at Each Execution Start

An execution start is the control-plane transaction that admits one attempt: an
initial run, a retry after failure or Worker loss, a resume after waiting on
input, a new scheduled fire, or a separately dispatched child task. Additional
model rounds or tool calls inside an already admitted attempt do not count as
new execution starts.

Before admitting an attempt, the owning subsystem verifies that the associated
Human is currently `active` and that `human_access_version` still matches. Any
admission ordered after `T0` fails, whereas an attempt admitted before `T0` may
finish even if its RPC reaches the Worker slightly after `T0` (no distributed
transaction spans PostgreSQL and Worker processes). If admission cannot read
authoritative Human state, it refuses to start the attempt.

Because disablement bumps `access_version`, a rapid disable-and-restore cycle
still invalidates queued runs and delayed retries that captured the pre-`T0`
version. Likewise, if a running attempt admitted before `T0` tries to dispatch
new child work after `T0`, that child work retains the Human association, runs
its own start check, and is rejected.

| Work | Required lifecycle result |
| --- | --- |
| Queued Human input, Turn, Background Agent Job, or Workflow task | End pending execution with the owner's stopped or cancelled result. |
| Checkback | Cancel its pending wake-up. |
| Cron schedule | Pause the rule and cancel pending fires; permit no further automatic or manual execution under its old authorization. |
| Automation Job | Cancel the definition and queued runs; permit no new trigger consumption under its old authorization. |
| Running attempt | Retain its completion rights and results; do not request an offboarding interrupt. |
| Retry, resumed attempt, Workflow continuation, or separately dispatched child | Check again and reject the invalid Human authorization. |
| Pending Human approval or confirmation | Reject that Human's response; another authorized Human must make a new decision. |

Each subsystem transitions its records through its own native lifecycle
([Schedule](Schedule.md), [Background Agent Job](BackgroundAgentJob.md),
[Workflow](Workflow.md), and [Automation Jobs](AutomationJobs.md)) rather than a
shared task engine or a single synthetic status, and completing an in-flight
attempt never reactivates a cancelled definition, schedules a next cron fire, or
revives stopped work.

Stopping future work requires no handover approval. The Console surfaces
affected work items and their revocation reasons, and its work-review view lists
items with `review_required` or missing, disabled, or superseded Human authority
in the selected tenant. From that view, an authorized operator can reauthorize a
paused cron rule (recording the prior `human_uid` and `access_version` without
automatically unpausing the schedule; the operator resumes it separately in
Cron). Terminal tasks and cancelled jobs must be recreated through their owners,
and editing a title or metadata field can never transfer a departed person's
credentials.

## Restore Access Explicitly

Restoring a disabled Human requires an authorized administrator, an explicit
audit reason, verified identity, and clearance of every active restriction. When
an upstream provider caused a restriction, current provider state must confirm
that the user is active again, though an upstream provider update never restores
Ankole access on its own.

Before a Human can return to `active`, an administrator must review and approve
their effective permissions in AuthZ (covering direct grants, static group
memberships, computed groups, and current directory memberships) so prior
administrator roles or sensitive grants cannot silently reactivate. Any revoked
grants are deleted from active AuthZ tables and preserved in audit history
rather than left as active rows marked historical.

`AuthZ.restoration_review/1` builds this review snapshot for the selected
tenant: it returns current direct grants, static memberships, computed group
definitions and their candidate grants, and all Userset grants (sorted by ID,
with source Page and action, target Page and scope, resource pattern, action,
and condition, including recursive paths). Because computed groups and grant
conditions evaluate per request and can inspect the Principal's display name and
avatar URL, the review fingerprint hashes all of these rules alongside the
Human's display name and avatar URL without claiming that every conditional rule
matches every resource. Even a seemingly cosmetic directory change to the
display name or avatar URL invalidates the fingerprint and requires a fresh
approval. After removing any unwanted grants or memberships in the AuthZ
editors, the administrator approves the current fingerprint; the restore
transaction verifies that the fingerprint has not drifted and records the
approved rules and identity check using standard AuthZ primitives.

A provider-originated restriction can be cleared only when a complete, `healthy`
directory snapshot (with any pending scope or large-removal review already
approved) observes the subject as active; neither a partial sync nor an OAuth
login profile suffices, and clearing a provider restriction neither clears a
separate manual restriction nor restores access by itself.

Pod administrators clear all eligible restrictions and restore the Human inside
one atomic transaction. If any restriction lacks healthy recovery evidence or
the permission fingerprint check fails, the transaction rolls back and keeps all
restrictions and the `disabled` state intact.

After restoration, the person must sign in anew: pre-disablement browser
sessions, OIDC tokens, cancelled jobs, and paused schedules remain invalid or
paused, restarting work requires a fresh authorized action, and personal
upstream tool authorizations must be re-established rather than reusing stale
local CLI profiles. Historical authorship, completed task outputs, drive files,
and Brain knowledge stay attributed to the original Principal UID under standard
data permissions; offboarding never widens access to private items, alters
retention policies, or rotates shared enterprise bot credentials.

## Console and Operations

In the Console, the Human list and detail views display the Human's access
state, identity source, active disable reasons, disable timestamp, acting
operator or upstream source, and latest successful directory check, keeping
provider sync health visually distinct from individual Human access state.

The UI also separates account disablement from background work cleanup:

- An in-flight attempt admitted before `T0` is shown as legitimately finishing
  rather than as a failed stop.
- Any work-cleanup failure names the affected record and exposes a retry button,
  and retrying cleanup never alters completed outputs or cancels cron rules that
  were explicitly reauthorized after `T0`.
- For each OIDC Client, the Console displays Back-Channel Logout registration
  and delivery status separately from local disablement and work cleanup,
  logging attempt counts, next retry timestamps, sanitized errors, and
  acknowledgements (never raw tokens), offering manual retry, and alerting when
  automatic retries are exhausted. A Client HTTP acknowledgement does not prove
  that every downstream app session has terminated.

Audit events record the Principal UID, operation or event ID, source, prior and
new states, reason, provider timestamp, receive timestamp, `T0`, operator,
revocation generation, and affected-work summary, without ever logging tokens,
secrets, or full directory payloads. Monitoring alerts fire on failed disable
events, repeated sync failures, anomalous directory drops, failed work-cleanup
sweeps, and zero active administrators, with every alert naming the target
record and recovery step.

User-facing login screens show an account-unavailable notice when a Human is
disabled and a temporary-service-failure notice when an upstream identity
provider is unreachable, never misreporting a network outage as employee
departure. Operators should track provider detection latency, local `T0` commit
latency, work-cleanup completion, and OIDC Client notification latency as
separate metrics: the 15-minute sync cadence is a detection target rather than a
hard end-to-end SLA, manual disablement remains available during provider
outages, and new logins and execution starts block immediately at `T0` without
waiting for background cleanup.

## Unresolved Work Classification

Before turning on automatic missing-member disablement for a directory, review
its API permissions, webhook subscriptions, full admission scope, and initial
baseline diff while preserving existing Principal UIDs and identity bindings.

Ankole assigns `authorization_kind = review_required` to work without verified
execution provenance. The control plane requires evidence of an Agent or system
execution source before it assigns service authorization. `created_by` records
the audit actor.

When execution admission first encounters a queued Signal with
`review_required`, it transitions that Signal to `dead_letter` with
`work_authorization_review_required`. An operator can inspect and classify the
item in the Console:

- Assign `service` authorization only when the recorded source proves that the
  work has no Human dependency; classifying an item never replays a dead-letter
  Signal or restarts stopped work automatically.
- To run a dead-letter Signal after classification, use `/retry signal::<id>`
  only when it satisfies the
  [exact retry conditions](Sessions.md#retry-reset-and-recovery); if the
  rejected Signal produced no visible durable reply, resubmit the original
  request under current authorization instead.
- For other paused or stopped work types, use the owning subsystem's resume or
  recreate action after classification.

Finally, any OIDC Client session issued without a recorded `sid` cannot receive
session-scoped Back-Channel Logout notifications.
