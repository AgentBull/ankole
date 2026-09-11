# Human Offboarding

Disabling a Human Principal prevents that person from signing in and starting
more work in Ankole. It also ends future execution of the person's existing
tasks, cron schedules, and automation jobs. The Principal UID, identity links,
work results, and audit history remain.

Ankole also provides standard Back-Channel Logout and Token Introspection for
OIDC Clients. Clients own their business sessions and can apply these results
with a delay; local disablement does not wait for them.

An attempt that passed its start check before disablement can finish. Ankole
does not add a permission check before each tool call or interrupt that attempt
because the Human status changed. A retry, a resumed attempt, or another
scheduled run must pass a new start check.

This document owns Human revocation, directory reconciliation, and cross-module
admission rules. The linked module documents own their storage and execution
contracts.

## Scope and Ownership

The scope is one private Ankole deployment instance. Feishu and DingTalk supply
automatic offboarding facts. Other identity providers can use the same
restriction operation without automatic detection.

| Owner | Responsibility |
| --- | --- |
| Feishu and DingTalk adapters | Verify and interpret provider events, user state, and directory coverage. |
| IdentityProviders and Directory | Run complete syncs, reconcile provider membership, and submit offboarding facts. |
| Principals | Store Human access state, disable reasons, identity links, and the persistent revocation fact. |
| AuthZ | Decide permissions, protect manual administrator operations, and control restored permissions. |
| Console and OIDC authentication | Reject disabled Humans and revoked credentials at their own request boundaries. |
| OIDC | Provide standard logout notifications and Introspection, and own Client/session records and notification delivery. |
| SignalsGateway, Schedule, Background Agent Jobs, Workflow, and Automation Jobs | Store the Human association of work, check it at execution admission, and stop future execution. |
| Agent Computer | Execute admitted attempts through the existing Worker contract. It does not own Human status or a separate permission list. |
| Console | Submit authorized operations and show account, sync, and affected-work results. |

The Elixir control plane owns durable state in PostgreSQL. Each work subsystem
keeps its existing lifecycle and public entry points. Oban can deliver durable
follow-up work; it does not own the Human access decision. Operator settings
belong to the owning subsystem's AppConfigure keys.

Ankole does not provide an HR system, another identity model, cross-enterprise
routing, automatic data deletion, or a general asset-transfer system for
offboarding.

## Keep the Existing Identity

Use the existing Human Principal UID. Keep provider-scoped identity bindings
and their unique keys when disabling or restoring a person. Keep the same OIDC
`issuer + sub`. A login, directory update, or delayed provider event must not
create an active replacement for a known disabled identity.

Keep the identity matching rules in [Principal](Principal.md), including contact
matching and provider aliases. Offboarding does not replace that matching
algorithm. A contact match to a disabled Principal must retain its disabled
state; it cannot restore access or grant the matched person the old permissions.
An existing provider binding remains authoritative.

A provider rebuild, a changed provider user ID, or a reused contact value is
not proof that the person may regain the old account. An administrator must
verify the identity before restoration or reassignment. Do not guess from a
display name, email address, or phone number during offboarding or recovery.

A person normally uses one login method. If one Principal has several methods,
disablement covers all of them, including local passwords and linked provider
accounts. Confirmed removal from the configured Ankole admission scope also
disables the whole Principal. There is no provider-only disabled state.
Separate accounts with no trusted link require explicit operator review.

## Store Disable Reasons Separately from Sync Health

Keep `active` and `disabled` as the Principal access states. Store the reason,
source, operation or event ID, and relevant times with the disable fact.
Several restrictions can apply at once. Clearing one restriction must not
clear another.

| Observation | Required result |
| --- | --- |
| Confirmed departure or exit from the enterprise | Disable the Human with that reason. |
| Confirmed freeze or suspension | Disable the Human without deleting profile data. |
| Authorized manual disable | Disable the Human and retain the operator's reason. |
| Confirmed removal from the configured admission scope | Disable the Human with a scope-removal reason. |
| Absence from a complete, trusted admission directory | Disable after the complete-sync checks below; record directory removal, not departure. |
| Timeout, missing permission, failed page, or unknown coverage | Report a sync failure; do not infer departure. |
| Return to the directory, unfreeze, or return to employment | Make recovery eligible for review; do not restore access automatically. |

The directory read scope and the application admission scope are different
provider facts. A smaller read scope alone is not evidence of departure or
loss of Ankole admission. The operator must identify which verified provider
scope controls admission.

## Stored Access and Directory State

`principals.access_version` is the durable Human revocation generation. Each
new restriction invalidates credentials and work that captured an earlier
version. `human_access_restrictions` stores independent active reasons with
provider recovery evidence. `human_access_events` stores immutable decisions,
permission approvals, and cleanup results. Duplicate source operations use a
unique `(source, operation_id, principal_uid)` key.

`identity_directory_events` stores provider events before acknowledgement.
`identity_directory_states` stores the latest revision, scope and snapshot
fingerprints, known members, missing candidates, sync health, and operator
review. Provider configuration changes and received events advance the revision.
A sync uses the exact saved configuration and cannot commit removal evidence
if that configuration or revision changed during collection.

For Lark, `sync.admissionScope = "none"` permits profile sync without automatic
missing-member removal. `"contact"` uses the provider contact scope only after
operator approval. Collection covers explicit users, departments, child
departments, and paginated group membership. It checks the scope again before
completion. `sync.maximumRemovalPercent` defaults to 20. Empty results and
scope changes require a new review even below that threshold. A provider
recovery check must belong to current successful directory evidence.

## Detect Offboarding

The Feishu adapter distinguishes user deletion, user updates, and scope
changes. The DingTalk adapter treats `user_leave_org` as a departure event; see
[DingTalk Adapter](plugins/DingTalkAdapter.md). A reliable departure event can
disable a known Human with only the stable provider identity; it does not need
a complete profile.

Resolve the event through existing provider bindings and aliases. If the
identity is unknown or the required IDs are missing, retain an actionable
failure for review. Do not create a new enabled Human from a departure event.
A pending departure fact for a known provider subject must be resolved before
a later login or sync can admit that subject as a new Human.

Acknowledge an event only after its result or its pending processing record is
durable. Duplicate events must be safe. Failed processing must be retryable.
Use provider ordering evidence when available. A stale update cannot undo a
disablement. If ordering is uncertain, query current provider state and keep
the existing restriction until recovery is authorized.

Use the existing directory-sync path for periodic and manual reconciliation.
The default is one full sync every 15 minutes. Before disabling missing
members, require all of these conditions:

1. The connection, permissions, admission scope, and all pages are valid.
2. The result covers the complete admission set for that identity provider.
3. Collection completes successfully before missing members are calculated.
4. A concurrent event or newer sync cannot be overwritten by an older result.
5. The operator has reviewed the initial identity and scope differences before
   automatic missing-member handling is enabled.

A scope change, unexplained empty result, or unusually large reduction stops
missing-member handling for that sync and produces a candidate list for review.
The reduction threshold is an operator setting. These checks must not suppress
a separate confirmed departure event. A failed collection may still leave
valid profile updates, but it is never evidence that unseen people departed.

## Disable the Human

An effective administrator with the existing Human-management permission can
disable an account from Console. The server checks permission and the current
target state. Repeated requests return the current result. Manual operations
protect against self-disablement and removal of the last effective Human
administrator.

Let `T0` be the commit time of the disable fact. Commit the disabled state,
persistent revocation fact, audit record, and durable requests to end future
work and notify OIDC Clients together. A failed downstream operation cannot
undo the disablement.
Task cleanup can retry after `T0`; execution admission must already reject the
disabled Human, even while cleanup is pending.

Confirmed provider departure can disable the last effective Human
administrator. This is an explicit exception to the current last-administrator
protection for manual operations. Keep that exception in the Principal/AuthZ
boundary. Do not add a global restricted-management state or leave the departed
administrator active.

An operator with control-plane shell and database access can grant administrator
access to an independently verified, active Human when no active administrator
remains. Run `mix ankole.admin.recover HUMAN_UID OPERATOR REASON --identity-verified`
from the control-plane directory with the deployment configuration. The command
records the operator and reason. It rejects a disabled target and refuses to run
while an active administrator exists. Establish and verify the replacement
Human through the existing Principal and identity-provider owners first. Zero active administrators must not
reopen public first-administrator setup or automatically restore the departed
person. See [AuthZ](AuthZ.md) for the existing administrator boundary.

## Reject New Authentication and Requests

Ankole checks Human access at each applicable authentication or request entry:

| Entry | Result after disablement |
| --- | --- |
| Local login, Feishu login, and SSO reuse | Reject a new authenticated session. |
| Console and OAuth browser sessions | Reject their next authenticated use on every device. |
| Authorization Code exchange and Refresh Token use | Reject credentials from the disabled or revoked authorization. |
| Console API, UserInfo, and Human AI Gateway requests | Reject the disabled Human, including an otherwise unexpired token. |
| Existing Human WebSocket | Reject a new protected request; an idle connection need not be closed. |
| Human signal, command, or approval input | Reject new action by the disabled Human. |

Console and OAuth retain separate authorization contexts within the
[Browser Sessions](BrowserSessions.md) lifecycle. Both use the persistent
Human revocation fact. Restoring `active` must not make an old
Cookie, Authorization Code, Refresh Token, or JWT usable again at Ankole.
Use an authentication generation or an equivalent durable mechanism owned by
the authentication path. A process restart or node change cannot erase it.

A request that already passed its check can complete. Do not interrupt an
existing response stream or recheck the Human between tools within an admitted
attempt. This does not remove existing token, Agent, resource, or turn-fence
checks. Ankole does not guarantee reversal of an external operation, including
one sent before `T0` that completes afterward.

## Notify OIDC Clients and Check Their Tokens

Deliver both Back-Channel Logout and Token Introspection as defined in the
[OIDC Server protocol extension](OIDCServer.md#offboarding-protocol-additions).
That document owns protocol fields, Client registration, authentication, and
notification delivery.

Account disablement invalidates all personal OIDC authorizations, including
Refresh Tokens issued with `offline_access`. This is an offboarding rule;
ordinary session logout does not define the same authorization lifetime.
Introspection after the disable commit reports the old authorization inactive
without waiting for notification delivery. Code exchange, refresh, UserInfo,
and Ankole's protected requests use the same revocation fact.

Notify every recorded Client session affected by the disablement. Delayed
notifications must still address the old session after the Human is restored.
Neither a new login nor restoration can reactivate an old authorization.

The Client owns the actual removal of its session and the decision to stop its
business requests. Ankole does not change Client-local accounts or business
permissions. Ankole owns protocol delivery; a particular business
application's deployment is outside Ankole.

Notification transport, retry, and Client caching can delay external logout.
There is no strict end-to-end logout deadline. Ankole must expose delivery
failures and current token validity; it cannot report local disablement as
proof that every Client has already blocked access.

## Associate Work with the Human

Agent and Session ownership keep their current meanings. An Agent's creator,
a task display name, or a reply channel alone does not identify whose account
must remain active for that task.

The control plane must retain the Human Principal associated with work accepted
on that person's behalf. Derive it from authenticated input and retain it
through child work, schedules, automation triggers, retries, and recovery.
The association is a control-plane fact, not a model-supplied owner field. Use
existing source records where they prove the association; each work owner must
persist any missing information needed after restart or source cleanup.

Work associated with the disabled Human stops future execution even if its
tools use an Agent or bot credential. A valid Agent token is not a substitute
for the associated Human's active account. Conversely, independent Agent or
system work with no Human dependency continues under its own authorization.
Do not disable an entire shared Agent or Session because one sender departed.
Reject that sender's pending instructions and retain other valid work.

Existing work with insufficient evidence of its Human association requires
operator classification before another execution. Do not interpret a missing
field as proof of independent service authorization. This is a migration and
manual recovery requirement, not a new delegation or task-ownership framework.

Each durable work owner stores `authorization_kind`, `human_uid`, and
`human_access_version`. `human` requires a Human and captured version; `service`
requires an evidenced independent source; `review_required` cannot execute.
`Ankole.Principals.WorkAccess` checks this fact in the owner's transaction and
provides the explicit legacy classification operation. It does not schedule
work or select an Agent. PostgreSQL checks the three-field shape.

## Check Once at Each Execution Start

An execution start is the control-plane admission of one attempt. It includes
an initial run, a retry after failure or Worker loss, a resumed run after a
wait, a new scheduled fire, and a separately dispatched child task. Another
model round or tool call within that same attempt is not a new start.

The owning subsystem checks the associated Human's current access and the
validity of the work's authorization before it admits the attempt. Admission
ordered after `T0` must fail. An attempt admitted before `T0` can finish even
if the Worker receives or starts it later. This admission point defines the
race boundary; no atomic guarantee spans the database and a Worker process.
If the check cannot read authoritative state, do not start the attempt.

Disablement invalidates the old work authorization as well as the account's
current access. A quick disable-and-restore must not let queued work, a delayed
retry, or a stale Worker assignment start under the old authorization. New
work dispatched by an already running attempt must pass its own start check
and retain the Human association.

| Work | Required lifecycle result |
| --- | --- |
| Queued Human input, Turn, Background Agent Job, or Workflow task | End pending execution with the owner's stopped or cancelled result. |
| Checkback | Cancel its pending wake-up. |
| Cron schedule | Pause the rule and cancel pending fires; permit no further automatic or manual execution under its old authorization. |
| Automation Job | Cancel the definition and queued runs; permit no new trigger consumption under its old authorization. |
| Running attempt | Retain its completion rights and results; do not request an offboarding interrupt. |
| Retry, resumed attempt, Workflow continuation, or separately dispatched child | Check again and reject the invalid Human authorization. |
| Pending Human approval or confirmation | Reject that Human's response; another authorized Human must make a new decision. |

Use existing lifecycle operations in [Schedule](Schedule.md),
[Background Agent Job](BackgroundAgentJob.md), [Workflow](Workflow.md), and
[Automation Jobs](AutomationJobs.md). Do not invent a common task engine or
force all of these objects into one terminal status. An admitted attempt's
completion must not reactivate a cancelled definition, plan a valid next fire,
or revive stopped work.

Ending future work requires no handover approval. Show affected objects and
their reasons in Console. An authorized person can review and explicitly
restart, replace, or reauthorize work through its existing owner. Changing a
label or an owner field cannot transfer the departed person's credentials.

## Restore Access Explicitly

Restoration requires an authorized administrator, a reason, a verified identity,
and clearance of all active restrictions. If the disabling source is a provider,
its current state must permit recovery. A provider update alone cannot restore
access.

An administrator must approve the effective permissions through AuthZ before
the Human becomes active. Review direct grants, static memberships, computed
groups, and current directory membership. Old administrator membership must not
silently become effective again. Keep only the permissions approved for the
restored Human; retain removed permissions as audit history, not active grant
rows merely labelled historical.
`AuthZ.restoration_review/1` returns the current direct grants, static
memberships, computed group definitions, and their possible grants. Computed
rules remain request-dependent; the preview does not assert that every rule
applies to every resource. Remove unwanted grants or memberships through their
existing editors, then approve the current fingerprint. The restore operation
rejects a changed fingerprint and records the approved rules and identity check.
This review uses existing AuthZ rules and does not add a second permission model.

The fingerprint includes the Principal display name and avatar URL because
AuthZ exposes both fields to computed groups and grant conditions. A directory
update to either field requires a new permission review, even when the change
looks cosmetic.

A provider restriction can be cleared only after a complete current snapshot
observes that subject as healthy. The directory must be `healthy`; a snapshot
that requires scope or removal approval must first receive that approval.
Neither a partial sync nor a login profile proves recovery. This requirement
does not clear an independent manual restriction or restore access by itself.

Require a new login after restoration. Old sessions, credentials, cancelled
jobs, and paused schedules remain invalid or inactive. Restarting work requires
a new authorized action. Personal provider authorization must be established
again before new work can use it; old local CLI profiles are not recovery proof.

Keep historical authors, task results, files, and knowledge under their original
Principal UID. Handover access follows existing data permissions. Offboarding
does not expose private data to other employees, change retention periods, or
rotate enterprise bot credentials and shared secrets.

## Console and Operations

The Human list and detail show access state, identity source, disable reasons,
disable time, operator or source, and the last successful source check. Show
sync health separately from Human access state.

Show account disablement and task cleanup as separate results. A running attempt
that was admitted earlier is allowed to finish and must be displayed that way;
it is not a failed stop. Show cleanup failures with the affected object and a
retry action. Repeated cleanup must not change a completed result or cancel work
that was explicitly reauthorized later.

Show logout registration and notification results for each OIDC Client. Keep
local account disablement, work cleanup, and Client notification status separate.
Record notification attempts, next retry time, errors, and acknowledgements
without token contents. Provide manual retry for failed notifications and alert
when automatic delivery is exhausted. Client acknowledgements do not prove
that every business request is now blocked.

Audit records include the Principal UID, operation or event ID, source, previous
and new state, reason, provider time, receive time, `T0`, operator, revocation
reference, and affected-work results. Never log tokens, secrets, or a complete
directory payload. Alert on failed disable processing, repeated sync failures,
unexpected directory reductions, failed future-work cleanup, and zero active
administrators. Each alert must identify the object and the recovery action.

Use an account-unavailable message for a disabled Human. Use a temporary-failure
message when an authentication dependency is unavailable. Do not report a network
failure as employee departure.

Measure provider detection delay, the local disable commit, future-work cleanup,
and Client notification delay separately. The periodic sync interval is a
detection target, not an end-to-end deadline. Provider outages and incomplete
scope can delay detection;
manual disable remains available. After the local commit, new authentication
and execution checks must reject the disabled Human without waiting for cleanup.

## Migration and Rollback

Before enabling automatic missing-member handling, review provider permissions,
event subscriptions, the full admission scope, and the initial differences.
Backfill work associations only from reliable records. Require manual review
for unresolved work. Preserve existing UIDs and identity bindings.

The migration backfills Human senders and work with a recorded source event
from that Human. This includes automation jobs that have such an event. A
legacy Console cron with only `created_by.principal_uid`, work without a proven
source, and events from non-Human senders remain `review_required`. Inspect
the unresolved-work list before rollout; its size depends on the stored facts.

An unresolved queued ActorEvent enters `dead_letter` when execution admission
first rejects it with `work_authorization_review_required`. Review and classify
it in Console. If execution is still required, use `/retry actor-event::<id>`
only when the event meets the existing
[exact retry conditions](SignalsGateway.md#async-work-units). A rejected
event with no visible durable reply cannot use that command; submit the
original request again under current authorization. Classification alone does
not replay a dead letter or restart stopped work. Other work types use their
existing owner's resume or restart action
after classification. Select independent service authorization only when the
recorded source proves that it has no Human dependency.

At rollout, require fresh authentication for sessions that lack the new
revocation mechanism. Inform users before invalidating those sessions. A rollback
must retain disabled accounts, revoked authorizations, and stopped future work;
an older runtime that cannot honor them must not resume serving those paths.

Include the OIDC Client/session records and pending notifications in migration
and rollback checks. A Client receives `sid` only in ID Tokens issued after this
mechanism exists; a Client session established before that has no
session-specific logout coverage. Preserve pending notification work on rollback.
