---
title: Conversations, signals, and sessions
description: The design choices and costs behind Ankole, with a source-checked comparison of deepseek-harness, pi durable, and qm.
section: Developer guide
order: 100.5
---

Ankole runs Agents for teams and organizations, where work can start from a chat message, a timer, an external event, or a completed background task—and every piece of work needs an accountable Principal and reliable recovery across process restarts.

To keep responsibilities clear, Ankole separates five records across distinct owners: a **conversation** stores participant messages, a **signal** admits new work, a **session** executes that work, **AIGateway** persists model session state, and **Delivery** tracks outbound sends to external platforms.

## Four design choices

### Keep messages and work in separate records

The conversation record holds the messages visible to human and Agent participants, whereas the work log holds model calls and tool results. Each participating Agent in a conversation owns its own Session and model state: all conversation participants can view the work in that Session, and a Session never crosses conversations.

Each Agent has its own Session in a conversation, and its visible output is shared with the conversation participants. Every turn accesses resources as the executing Agent, including interactive, human-woken `may_intervene`, scheduled and service-triggered turns. Agent messages never wake other Agents. Human employment and instruction versions still determine whether delegated work may continue; they do not intersect Human grants with Agent resource access.

### Admit every stimulus through Signals

Messages, timers, external events, and task completions all enter through one admission owner in `Ankole.Signals`, which persists the Signal, removes duplicates, records attribution and authorization, and resolves the target Session.

A Signal may name its target Session directly; otherwise, Ankole selects the target through conversation participation or a Signal Routing Rule. Conversation-host adapters both observe incoming messages and deliver replies, whereas event-source adapters only emit Signals—allowing new event sources to integrate without adding a separate admission mechanism.

### Separate scheduled work from the conversation's session

Each cron schedule runs in its own stable `cron:<schedule_id>` Session, and each background task likewise runs in its own Session. When either posts its output to a conversation, the conversation's next turn reads that posted message cleanly without importing the other Session's internal model calls and tool results.

### Keep one owner for model state

AIGateway provides stateful Responses chains and hosted tools for both internal Agents and external API clients: the Session runtime selects inputs, tools, continuation checkpoints, and compaction triggers, while AIGateway stores the model transcript and executes those operations.

An AIGateway conversation represents model session state rather than the shared participant conversation—duplicating Agent transcript history inside the Session runtime would create a second competing model-state store.

## Source-checked comparison

The comparison below references these repository snapshots, verified on **2026-10-14**:

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

Note that qm's `SPEC.md` still refers to “tape” as a design term while documenting its completed move to `session_entries` and subsequent database cleanup; the table above reflects qm's inspected code rather than its earlier dual-write design. [Source][Q-spec]

## Costs and accepted limits

- **More concepts and code.** Separating conversations, signals, sessions, delivery, and model state requires maintaining distinct subsystem boundaries.
- **Two records to inspect.** Diagnosing an incident can require reading both the conversation's messages and the Session's work log.
- **Shared work can surface results to the room.** Information retrieved by the executing Agent and included in its reply enters the conversation's shared context. Available tools come from its tool catalog; operations inside a tool authorize their resources as the Agent. Human instruction validity is checked separately. In comparison, qm filters session history dynamically per audience. [qm source][Q-audience]
- **Heavier infrastructure.** Running PostgreSQL transactions and an OTP control plane adds latency and operational overhead compared with a local single-file harness.
- **Uncommitted streaming text is ephemeral.** If a process crashes mid-stream, uncommitted partial text is discarded; during recovery, the Session Driver may repeat an interrupted model call, reuses committed tool results, and avoids blindly repeating uncertain Worker operations, so external side effects carry no exactly-once guarantee. By contrast, `pi durable` publishes progress only after storage commit. [Source][P-guide]
- **Wire-protocol constraints.** Stateful continuations require an upstream or gateway wire format capable of replaying stored response items losslessly.
- **One admission contract across every source.** Every event producer and channel adapter must conform to `Ankole.Signals`.
- **Cron session history accumulates.** Because `cron:<schedule_id>` Sessions preserve context across fires, they rely on periodic compaction, whereas qm opens a fresh session on every cron fire. [Source][Q-cron]

## When another approach fits better

- **Single developer working locally with one Agent:** `deepseek-harness` or `pi` requires far less deployment setup.
- **Embedding a resumable Agent loop inside your own app:** `pi durable` offers a smaller library-sized boundary.
- **A Slack-centered team assistant built around a unified session tape:** `qm` provides a more direct single-log design.

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
