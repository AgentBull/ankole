---
title: Conversations, signals, and sessions
description: The design choices and costs behind Ankole, with a source-checked comparison of deepseek-harness, pi durable, and qm.
section: Developer guide
order: 100.5
---

Ankole runs Agents for organizations. Work can start from a message, a timer, an external event, or a completed task. That work needs a responsible Principal and recovery after a process restart.

Three facts have different owners: a **conversation** preserves participants' messages; a **signal** starts work; a **session** executes it. AIGateway preserves model session state. Delivery records the intent and result of an external send.

## Four design choices

### Keep messages and work in separate records

The conversation record contains messages that participants can see. The work log contains model calls and tool results. Each Agent in a conversation has its own session and model state. The work in each session is visible to all conversation participants. The session does not cross conversations.

An addressed turn uses the requester's authorization. An intervention uses the Agent's identity by default. Existing intervention policy can identify a person as the current requester and use that person's authorization. Visibility follows the conversation; execution follows the identity for that turn.

### Admit every stimulus through Signals

Messages, time, external events, and task completion use one admission owner. It persists the signal, removes duplicates, records attribution and authorization, and resolves the target.

A signal can name its target session directly. Otherwise, participation or a Signal Routing Rule selects the target. Conversation-host adapters observe messages and deliver replies. Event-source adapters only supply signals. A new source does not need another admission mechanism.

### Separate scheduled work from the conversation's session

A cron rule uses a stable session, `cron:<schedule_id>`. A background task uses its own session. Either can send its result to a conversation. The conversation's next turn reads that message, without importing the other session's model calls and tool results.

### Keep one owner for model state

AIGateway provides stateful Responses calls and hosted tools for internal Agents and external clients. The runtime selects inputs, tools, continuation, and compaction. The platform saves model state and performs those operations.

An AIGateway conversation is model session state. It is separate from the shared conversation between participants. Moving Agent history into the runtime would create a second model-state implementation.

## Source-checked comparison

The comparison below uses these repository snapshots, checked on **2026-10-14**. Links point to the inspected commits.

| Project | Verified commit |
| --- | --- |
| deepseek-harness | [`571902028a75`](https://github.com/deepseek-ai/deepseek-harness/commit/571902028a75c64c1d767f4ae5fd099485f0ddf0) |
| pi (`packages/durable`) | [`910149912ca2`](https://github.com/earendil-works/pi/commit/910149912ca29d7ae4eaa945bb2b53eb84c68264) |
| qm | [`cf0e475f50c0`](https://github.com/yc-software/qm/commit/cf0e475f50c061e0ae00701999fb14a9272bba7d) |

| Aspect | deepseek-harness | pi durable | qm | Ankole |
| --- | --- | --- | --- | --- |
| Record model | Append-only `SessionEvent` log; model history is a projection. [Source][D-session] | Immutable entries; task and document updates commit atomically. [Source][P-spec] | PostgreSQL `session_entries`; Slack and Web UI project session history. [Store][Q-session], [design][Q-spec] | Separate conversation messages and model work log |
| Shared context | Agent/session history with plugin-defined projections. [Source][D-session] | The host defines message types and application policy. [Source][P-guide] | History must be visible to every member of the turn's audience. [Source][Q-audience] | One session per Agent in a conversation; shared audience, separate model state; authorization per turn |
| Incoming work | Agent input and scheduled follow-ups; a separate webhook runtime. [Schedule][D-schedule], [webhook][D-webhook] | Submissions and a persistent inbox. [Source][P-guide] | Crons, webhooks, and loops have separate mechanisms; its SPEC criticizes the separate loop machinery. [Source][Q-spec] | One durable signal admission contract for every source |
| Time and external triggers | Durable reminders return to the original session. Webhooks lack a queue, retry, replay, and built-in deduplication. [Schedule][D-schedule], [webhook][D-webhook] | The package supplies submission/task APIs; the host supplies external triggers. [Source][P-guide] | Each cron fire uses `cron:<id>:fire:<hash>`. [Source][Q-cron] | A stable cron session; durable external signals; results can enter a target conversation |
| External delivery | Reminder delivery stays in the original session. [Source][D-schedule] | External channels belong to the host application. [Source][P-guide] | Persistent delivery records with expiry. [Source][Q-delivery] | Conversation-host adapters; bounded retry; failed, expired, and unknown outcomes |
| Storage and concurrency | Local JSONL backend; one writer per session, protected by an OS lock. [Source][D-store] | Memory, SQLite, JSONL, or Durable Object storage; one owning process, no cross-process locking. [Source][P-guide] | PostgreSQL; current code reads and writes `session_entries`. [Source][Q-session] | PostgreSQL is authoritative; tenant isolation; authorization checked at each execution start |
| Model context | Derived from the session log. [Source][D-session] | Reduced from committed entries. [Source][P-spec] | Built from audience-filtered history. [Source][Q-audience] | Stored and continued by AIGateway; runtime decides inputs |

qm's SPEC still uses “tape” as a design term. It records the completed switch to `session_entries` and later database cleanup. The comparison uses current code, rather than the earlier dual-write design. [Source][Q-spec]

## Costs and accepted limits

- **More concepts and code.** Conversations, signals, sessions, delivery, and model state need separate owners.
- **Two records to inspect.** Diagnosis can require both conversation messages and the session's work log.
- **Shared work can disclose results to the group.** Data obtained with a requester's authority enters the conversation's shared context. qm instead filters history for the audience. Future function-call permissions must use the current turn's identity. [qm source][Q-audience]
- **A heavier deployment.** PostgreSQL transactions and a control plane add latency and operations compared with a local file harness.
- **Partial text is not durable.** A crash can lose unfinished text. Recovery can repeat model calls, reuses recorded tool results, and does not blindly repeat uncertain operations. External side effects have no exactly-once guarantee. pi durable publishes progress only after storage commit. [Source][P-guide]
- **Platform constraints.** Stateful requests need a wire format that can replay stored items without loss.
- **One contract requires migration.** Every producer and adapter must adopt it.
- **Cron history grows.** Stable cron sessions retain context and require compaction. qm starts a fresh session for each fire. [Source][Q-cron]

## When another approach fits better

- For one developer working locally with one Agent, deepseek-harness or pi can require less deployment work.
- For embedding a resumable Agent loop in an application, pi durable supplies the smaller runtime boundary.
- For a team assistant centered on Slack and model-oriented session history, qm offers the more direct structure.

Read [Architecture](../architecture/) for the message-to-work flow and [Quick start](../quickstart/#terminology) for the canonical terms.

[D-session]: https://github.com/deepseek-ai/deepseek-harness/blob/571902028a75c64c1d767f4ae5fd099485f0ddf0/packages/core/session/README.md
[D-store]: https://github.com/deepseek-ai/deepseek-harness/blob/571902028a75c64c1d767f4ae5fd099485f0ddf0/packages/session/session-persistence-jsonl/README.md
[D-schedule]: https://github.com/deepseek-ai/deepseek-harness/blob/571902028a75c64c1d767f4ae5fd099485f0ddf0/packages/schedule/schedule/README.md
[D-webhook]: https://github.com/deepseek-ai/deepseek-harness/blob/571902028a75c64c1d767f4ae5fd099485f0ddf0/packages/experimental/webhook/README.md
[P-guide]: https://github.com/earendil-works/pi/blob/910149912ca29d7ae4eaa945bb2b53eb84c68264/packages/durable/README.md
[P-spec]: https://github.com/earendil-works/pi/blob/910149912ca29d7ae4eaa945bb2b53eb84c68264/packages/durable/docs/spec.md
[Q-session]: https://github.com/yc-software/qm/blob/cf0e475f50c061e0ae00701999fb14a9272bba7d/src/sessions/postgres-session-store.ts
[Q-audience]: https://github.com/yc-software/qm/blob/cf0e475f50c061e0ae00701999fb14a9272bba7d/src/resolution/context-filter.ts
[Q-cron]: https://github.com/yc-software/qm/blob/cf0e475f50c061e0ae00701999fb14a9272bba7d/src/cron/scheduler.ts
[Q-delivery]: https://github.com/yc-software/qm/blob/cf0e475f50c061e0ae00701999fb14a9272bba7d/src/delivery/delivery-store.ts
[Q-spec]: https://github.com/yc-software/qm/blob/cf0e475f50c061e0ae00701999fb14a9272bba7d/docs/SPEC.md
