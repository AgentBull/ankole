# Agent Token Quota

An Agent token quota limits the number of tokens that one Agent can consume
during a repeating period. In the Agent Console, an operator sets the period
length in days, the period start time, and the token limit for each Agent. When
an Agent reaches its limit, AIGateway rejects further model requests from that
Agent until the current period ends or an operator resets the quota.

The Elixir control plane owns every part of quota enforcement; Workers keep no
usage counters. Within the control plane, `Ankole.AIAgent.TokenQuota` manages
quota configuration and usage queries, AIGateway maintains the usage ledger and
rejects over-quota requests, and `Sessions.Notices` formats the user-facing
notice. When AIGateway rejects a request on a control-plane Session, the Session
Driver reads that rejection directly. On a Background Agent Job, by contrast,
the Worker reports a usage-limit error from Codex as pool exhaustion, so the
control plane checks the Agent's quota before settling the Job failure.

## What Counts

AIGateway records every classified LLM provider round in
`ai_gateway_usage_records`, but only rows whose origin is `agent` or `codex`
count toward an Agent's quota window. Agent credentials therefore cover every
model call in a control-plane Session—including scheduled, Workflow, and ambient
runs—as well as Background Agent Jobs. If an Agent request starts compaction
through a `compaction_trigger` item, that compaction keeps the Agent or Codex
origin and counts the same way.

The ledger has six origins, assigned in this priority order:

1. `codex` for an Agent subject using the Codex protocol;
2. `agent` for every other Agent subject;
3. `oidc_human` for an OIDC Human subject, including explicit compaction;
4. `compaction` for an internal `compaction.summary` caller;
5. `applet` for an internal `pod_applet` caller; and
6. `brain` for `brain` and phase-specific `brain.*` callers.

Explicit subject credentials always take precedence over a caller label. Only
unbound control-plane calls use caller-based classification. Automatic
compaction and `/compact` write `compaction` rows and never enter an Agent
window. Brain calls execute as `ankole_brain` and Applet calls as `system`,
with each tenant's system Principals owning separate ledger rows and neither
consuming an Agent quota. Embedding, rerank, web search, web fetch, and image
generation do not write these LLM usage rows.

For each provider round that ends with `response.completed` or
`response.incomplete`, the ledger records `usage.input_tokens` and
`usage.output_tokens` as that provider reported them, and counts their sum.
Cached input tokens remain part of `input_tokens` without separate weighting,
and Ankole counts raw tokens equally regardless of which model ran. The ledger
starts empty at deployment.

The quota acts as a soft limit: AIGateway checks accumulated usage before
dispatching a request and rejects the request when usage is already at or above
the limit. Because the check happens before dispatch, a single in-flight request
can finish with total usage above the limit. `ai_gateway_usage_records` tracks
raw token counts without currency or pricing as an instance-local guardrail per
Agent, and applies alongside (`AND`) any compute or account admission hook
enforced by a plugin.

## Data Model

`ai_gateway_usage_records` stores one row for each counted provider round:

| Field | Meaning |
| --- | --- |
| `id` | UUIDv7 primary key |
| `subject_uid` | The executing Agent, Human, or system Principal |
| `origin` | `agent`, `codex`, `oidc_human`, `compaction`, `applet`, or `brain`; only the first two enter Agent quota windows |
| `model` | The resolved `provider_id/model` selector |
| `input_tokens`, `output_tokens` | Non-negative provider usage of the round |
| `session_id` | The Session whose Turn made the round; `job:<id>` for a Background Agent Job; NULL when unknown |
| `signal_id` | The Signal that started that Turn; NULL when unknown |
| `job_id` | The Background Agent Job that made the round; NULL for other work |
| `attempt` | The attempt number of that Job; NULL for other work |
| `inserted_at` | Record time; the window query uses it |

PostgreSQL uses an index on `(subject_uid, inserted_at)` to compute the window
sum, along with partial indexes on `job_id` and `(session_id, inserted_at)` for
per-Job and per-Session sums. AIGateway reads the attribution columns from the
round's request context; if an attribution value has the wrong shape, AIGateway
drops that value and writes `NULL` in that column so that malformed attribution
never blocks quota accounting. While an Agent exists, AIGateway never updates or
deletes its ledger rows; deleting the Agent Principal removes its ledger
together with its other AIGateway records. If writing to the ledger fails (for
example, because of a database error), AIGateway logs a warning without failing
the model response. See [AIGateway](AIGateway.md) for how Session Turns and
Background Agent Jobs supply work identity.

Ankole stores the quota configuration in
`agents.options["ai_agent"]["token_quota"]`, alongside `models` and
`provider_hosted`:

| Field | Meaning |
| --- | --- |
| `period_days` | Integer, at least 1 |
| `period_start_at` | UTC instant that starts the first period |
| `limit_tokens` | Integer, at least 1 |

If an Agent has no `token_quota` object, no token limit applies.
`Ankole.AIAgent.TokenQuota` validates and writes this object inside a single
`Repo.transact_top_level/2` transaction that locks the Agent row, using the same
pattern as model profiles.

## Periods

Each period spans `period_days` multiplied by 24 hours, tiling the timeline in
both directions from `period_start_at`:

```text
period_length = period_days × 86400 s
window_start  = period_start_at + floor((now − period_start_at) / period_length) × period_length
window_end    = window_start + period_length
```

An Agent's usage for the current window is the sum of its ledger rows with
`inserted_at` at or after `window_start`. Operators can set `period_start_at` in
the future; Ankole computes and counts the window preceding a future start time
with the same formula.

When an operator resets a quota, `Ankole.AIAgent.TokenQuota` sets
`period_start_at = now`. This immediately ends the current window and starts a
new window with zero counted usage at the reset timestamp, while keeping older
ledger rows for audit. Similarly, if an operator updates `period_days` or
`period_start_at`, Ankole recomputes the active window from the new values, and
if an operator updates `limit_tokens`, the new limit takes effect on the next
check. None of these configuration changes modify existing ledger rows.

Because periods use fixed 24-hour multiples rather than calendar days, a
daylight-saving transition shifts the local wall-clock boundary by one hour.

## Enforce the Limit

When resolving the model for an `llm` request—both in
`ResponsesPreparation.resolve_runtime` and at the WebSocket `response.create`
entry—AIGateway checks the quota before selecting a model or credential.
AIGateway runs this check whenever `subject_type` is `agent`; other in-process
callers omit `subject_type` and skip the check. When a request includes a
`compaction_trigger`, AIGateway carries the caller's identity into the local
summarizer or upstream provider compaction call, so compaction is checked and
counted just like the parent request. Because AIGateway enforces the quota
before credential selection, a rejection does not touch any credential, and an
Agent at its limit receives the quota error even when its credential pool is
also exhausted.

When an Agent is at or above its limit, AIGateway returns HTTP 429 with this
error object:

```json
{
  "code": "agent_token_quota_exceeded",
  "type": "usage_limit_reached",
  "message": "The Agent has used its token quota for the current period.",
  "retryable": false,
  "resets_at": 1757980800,
  "details_json": {
    "used_tokens": 1200000,
    "limit_tokens": 1000000,
    "window_ends_at": "2026-09-16T00:00:00Z"
  }
}
```

Along with the body, AIGateway sends the same `retry-after` and reset headers
used for credential-pool rejections, setting the recovery time to the end of the
current window, while `retryable: false` tells callers that a retry cannot
succeed.

Different callers interpret this error according to their runtime boundary. The
`type` field (`usage_limit_reached`) satisfies the Codex boundary contract,
because the pinned Codex runtime does not retry HTTP 429 responses with that
type. On the main Agent path, the Session Driver reads `code` directly from the
error object. On a Background Agent Job, the Worker reports the Codex
usage-limit failure to the control plane as `credential_pool_exhausted`; when
settling the Job attempt, the control plane checks the Agent's quota and records
the terminal `agent_token_quota_exceeded` verdict if the quota is exhausted.

For requests that run, AIGateway appends ledger rows at its two usage
observation points: on the streaming terminal event in `ResponseStream`, and
upon completion of a non-streaming request in `AIGateway`. Every transport uses
one of these two points.

## Tell the User

Before a main or Workflow Session turn starts, `Sessions.Admission` checks the
Agent's quota through `Ankole.AIAgent.TokenQuota` (Background Agent Job
admission skips this preflight check). If the Agent has reached its limit,
`Sessions.Notices` closes the input and commits one localized Delivery notice
when the event is eligible for a reply. Before closing the input, it restores
any committed tool records and applied inputs so that a failed preflight does
not erase work that already committed. The Delivery record uses the
`ai-token-quota-exceeded` key prefix, and `Sessions.Notices` formats the message
with `conversations.delivery.reply.token_quota_exceeded`, reporting the used
tokens, limit, and window end in the installation timezone (`system.timezone`).
For an ambient `im.message.may_intervene` input, Ankole completes the input
without sending a notice, just as it does when a model profile is missing.

A turn can also cross its limit after passing admission. When that happens,
AIGateway rejects the subsequent model call, and the Session Driver settles the
non-retryable failure as a dead letter. Because the failure carries
`agent_token_quota_exceeded`, `Sessions.Notices` sends the quota notice instead
of the generic retry text.

After an operator resets the quota or a new window begins, the user must send
their message again; Ankole does not automatically replay blocked messages.

## Background Agent Jobs

Background Agent Job creation and admission do not check the token quota.
Instead, if an Agent is over its limit, AIGateway rejects the first Codex
request of the Job. The Worker then reports `credential_pool_exhausted`, and the
control plane checks the Agent's quota and fails the Job with
`agent_token_quota_exceeded` through the terminal Job path. As a result, the Job
neither returns to `queued` nor waits for the next window. The owner Session
receives the standard `background_agent_job.failed` event; if the main Agent is
also at its limit when handling that event, its turn produces the quota notice
described above.

## Console

The Agent Console displays a `Token quota` section next to `Model profiles`. It
shows the period length, the period start time, the token limit, a usage bar
with used tokens and their share of the limit, the start and end times of the
current window, and a `Reset` button with a confirmation dialog. Operators edit
the period start time with a date-time picker in their browser time zone at
whole-second precision. In storage, Ankole preserves the exact UTC precision of
`period_start_at` (including microseconds written by a reset), and when saving
the form, the Console omits `period_start_at` if the operator did not change the
picker value.

The HTTP routes are:

- `GET /api/v2/agents/:agent_uid/token-quota`
- `PUT /api/v2/agents/:agent_uid/token-quota`
- `DELETE /api/v2/agents/:agent_uid/token-quota`
- `POST /api/v2/agents/:agent_uid/token-quota/reset`

Write requests place action arguments inside `data`. `PUT` always requires
`period_days` and `limit_tokens`. If the caller omits `period_start_at` when
updating an existing quota, the control plane retains the stored start time
under the Agent row lock; however, when configuring a quota for an Agent that
does not have one yet, the caller must supply a valid `period_start_at`. Passing
an explicit start time replaces the stored instant, while `null` and invalid
values are rejected.

Every route returns both the quota configuration and the current usage window:

```json
{
  "token_quota": {
    "period_days": 7,
    "period_start_at": "2026-09-09T00:00:00Z",
    "limit_tokens": 1000000
  },
  "usage": {
    "window_started_at": "2026-09-09T00:00:00Z",
    "window_ends_at": "2026-09-16T00:00:00Z",
    "used_tokens": 1200000,
    "exceeded": true
  }
}
```

If an Agent has no configured limit, both `token_quota` and `usage` are `null`,
and calling `POST .../reset` for that Agent returns HTTP 422 with
`token_quota_not_configured`.

Principal/AuthZ authorizes these operations on
`site_console:agent:<uid>:token_quota` with the `read`, `update`, and `delete`
actions. To keep ownership clear, the generic `PATCH /agents/:agent_uid` route
rejects `options.ai_agent.models`, `provider_hosted`, and `token_quota` with
HTTP 422. When `PATCH /agents/:agent_uid` replaces `options`, the control plane
locks the Agent row first and preserves the stored values of model profiles,
provider-hosted tools, and `token_quota`—including any quota written while the
update waited for the lock. Likewise, `POST /agents` rejects
`options.ai_agent.token_quota` with HTTP 422; operators configure a quota after
creating the Agent through the dedicated token-quota route.

## Rules

- AIGateway is the sole enforcement point; the preflight check in `Sessions.Admission` only avoids starting a model turn that would immediately fail.
- `ai_gateway_usage_records` is append-only while the Agent exists and is the sole usage source for quota checks.
- Neither the Worker nor the control plane retries a quota rejection.
- Resetting a quota starts a new period immediately without deleting ledger rows.
- An Agent without a `token_quota` object has no token limit.
