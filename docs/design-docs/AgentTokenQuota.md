# Agent Token Quota

An Agent token quota limits the tokens that one Agent can consume in a
repeating period. An operator sets the period length in days, the period start
time, and the token limit for each Agent in the Agent Console. When the Agent
reaches the limit, AIGateway rejects its model requests until the period ends
or the operator resets the quota.

The Elixir control plane owns every part of the quota. `Ankole.AIAgent.TokenQuota`
owns the configuration and the usage query. AIGateway owns the usage ledger and
the rejection. SignalsGateway owns the user notice. Agent Computer only
classifies the rejection as a terminal error; it keeps no usage counters.

## What Counts

A request counts when it carries an Agent token, so its `subject_type` is
`agent`, and it uses the `llm` capability. This covers every model call in a
Worker turn, including scheduled, workflow, and ambient turns, and every request
of a Background Agent Job. A compaction that such a request starts with the
`compaction_trigger` item, including the Codex remote compaction call, is that
request's own model work and counts the same way.

For each provider round that ends with `response.completed` or
`response.incomplete`, the ledger records `usage.input_tokens` and
`usage.output_tokens` as the provider reported them. The counted amount is
their sum. Cached input tokens are part of `input_tokens` and are not
separated. The model does not change the count.

These requests do not count:

- Brain model calls. They run in the control plane as the maintainer Agent with
  a `caller` label and no `subject_type`.
- Compaction that the control plane starts on its own: automatic compaction
  inside a stateful Response, and manual compaction from the Console or a chat
  command. They also run in-process.
- Embedding, rerank, web search, web fetch, and image generation tool usage.
- Requests with an OIDC Human token or an administrator Console token.

The ledger starts empty at deployment. Usage before that is not counted.

The limit is a soft limit. AIGateway checks the usage before it sends a request
and rejects the request when the usage is at or above the limit. One request
can therefore end above the limit by its own usage.

## Data Model

`ai_gateway_usage_records` stores one row for each counted provider round:

| Field | Meaning |
| --- | --- |
| `id` | UUIDv7 primary key |
| `subject_uid` | The Agent Principal |
| `origin` | `agent` for a Worker turn, `codex` for a Background Agent Job request |
| `model` | The resolved `provider_id/model` selector |
| `input_tokens`, `output_tokens` | Non-negative provider usage of the round |
| `inserted_at` | Record time; the window query uses it |

An index on `(subject_uid, inserted_at)` serves the window sum. Rows are never
updated or deleted while the Agent exists. Deleting the Agent Principal removes
its ledger with its other AIGateway records. A ledger write failure, including
a database error, logs a warning and does not fail the response.

The quota configuration lives in `agents.options["ai_agent"]["token_quota"]`,
next to `models` and `provider_hosted`:

| Field | Meaning |
| --- | --- |
| `period_days` | Integer, at least 1 |
| `period_start_at` | UTC instant that starts the first period |
| `limit_tokens` | Integer, at least 1 |

An Agent without this object has no limit. `Ankole.AIAgent.TokenQuota`
validates and writes the object in one transaction that locks the Agent row,
in the same shape as model profiles.

## Periods

A period is `period_days` multiplied by 24 hours. Periods tile the timeline
from `period_start_at` in both directions:

```text
period_length = period_days × 86400 s
window_start  = period_start_at + floor((now − period_start_at) / period_length) × period_length
window_end    = window_start + period_length
```

The usage of the current window is the ledger sum for the Agent with
`inserted_at` at or after `window_start`. A period start in the future is
valid; the window before it is counted the same way.

A reset writes `period_start_at = now`. The current window ends at once, a new
window starts at the reset instant, and its usage is zero. Older ledger rows
stay for audit. A change of the period or the start time recomputes the window
from the new values. A change of the limit applies to the next check. No
change touches the ledger.

Periods use fixed 24-hour multiples, not calendar days. A daylight-saving
change moves the local wall-clock boundary by one hour.

## Enforce the Limit

AIGateway checks the quota when it resolves the model of an `llm` request, in
`ResponsesPreparation.resolve_runtime` and in the WebSocket `response.create`
entry, before the model and its credential are selected. A request with
`subject_type` `agent` is checked; in-process callers pass no `subject_type`
and skip the check. A compaction trigger carries the same identity into the
summarizer or the provider compaction call, so it is checked and counted like
the request that sent it. The rejection touches no credential, and an Agent at
its limit receives the quota answer even when its credential pool is also
exhausted.

The rejection is HTTP 429 with this error object:

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

The response carries the same `retry-after` and reset headers as a credential
pool rejection, with the window end as the recovery time, and the header
`x-codex-promo-message` whose text contains the code. `retryable: false` tells
the Worker that a retry cannot succeed.

The `type` and the header are the Codex boundary contract. The pinned Codex
runtime never retries a 429 whose `type` is `usage_limit_reached`; it reports
its own usage-limit error and repeats the `x-codex-promo-message` text
verbatim in that error's message. Every other 429 body becomes a Codex
retry-limit error whose message keeps only the status, so the code would not
reach the Worker. The main Agent path reads the code from the error object
directly.

Agent Computer classifies `agent_token_quota_exceeded` as a non-retryable error
before its generic 429 rule, so the turn ends on the first rejection without
local retries. The Codex runner finds the code in the Codex error message
before its credential-pool-exhaustion rule and ends the Job turn with the same
code, `retryable: false`, and status 429.

AIGateway records ledger rows at its two existing usage observation points:
the streaming terminal event in `ResponseStream` and the completed
non-streaming request in `AIGateway`. Every transport uses one of them.

## Tell the User

Before a conversation turn starts, `TurnLifecycle` checks the quota through
`Ankole.AIAgent.TokenQuota`. Job turns pass `conversation: :none` and skip
this check. When the Agent is at its limit, the turn does not start:
`TurnStartFailure` completes the ActorEvent and, for a channel-reply-eligible
event, commits one localized notice through the Outbox with the
`ai-token-quota-exceeded` key prefix. The notice uses
`signals_gateway.reply.token_quota_exceeded` and states the used tokens, the
limit, and the time the window ends in the installation timezone
(`system.timezone`). An ambient `im.message.may_intervene` event completes
without a notice, as for a missing model profile.

A turn that starts under the limit can cross it. AIGateway then rejects a
later model call, the Worker aborts the turn as non-retryable, and ActorRuntime
moves the event to `dead_letter`. The dead-letter notice uses the same quota
text when the abort reason carries the `agent_token_quota_exceeded` code, so
the user does not receive the generic retry text.

After a reset or a new window, the user sends the message again. Nothing
replays a blocked message.

## Background Agent Jobs

Job creation and admission do not check the quota. The first Codex request of
an over-limit Job is rejected, the Worker ends the turn with
`agent_token_quota_exceeded`, and the control plane fails the Job with that
code through the existing terminal path. The Job does not return to `queued`
and does not wait for the next window. The owner session receives the ordinary
`background_agent_job.failed` event. When the main Agent is also at its limit,
that turn produces the quota notice above.

## Console

The Agent Console has a `Token quota` section next to `Model profiles`. It
shows the period length, the period start time, the limit, a usage bar with
the used tokens and their share of the limit, the start and end time of the
current window, and a `Reset` button with a confirmation dialog. The period
start time is a date-time picker in the operator's browser time zone; the
stored value is a UTC instant at second precision.

The routes are:

- `GET /api/v1/agents/:agent_uid/token-quota`
- `PUT /api/v1/agents/:agent_uid/token-quota`
- `DELETE /api/v1/agents/:agent_uid/token-quota`
- `POST /api/v1/agents/:agent_uid/token-quota/reset`

Every route answers with the configuration and the current window:

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

`token_quota` and `usage` are both `null` for an Agent without a limit, and a
reset of such an Agent answers 422 `token_quota_not_configured`. The AuthZ
resource is `agent:<uid>:token_quota` with the `read`, `update`, and `delete`
actions. The
generic `PATCH /agents/:agent_uid` route rejects `options.ai_agent.models`,
`provider_hosted`, and `token_quota` with 422 and keeps their stored values
when it replaces `options`, so a whole-`options` write from an older client
cannot remove model profiles or the quota. It locks the Agent row before the
merge, so a quota written while the update waits is kept. `POST /agents`
rejects `options.ai_agent.token_quota` the same way; a quota is set after
creation through its own route.

## Rules

- AIGateway is the only enforcement point. The SignalsGateway check only avoids a Worker turn that cannot start.
- The ledger is append-only while the Agent exists and is the only usage source for the quota.
- Neither the Worker nor the control plane retries a quota rejection.
- A reset starts a new period. It never deletes ledger rows.
- An Agent without a `token_quota` object has no limit.
