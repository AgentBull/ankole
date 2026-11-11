# Ankole Lifecycle Overview

The ten state machines below trace how Ankole advances each runtime concern through its lifecycle: chat turns, long-running work, Agent Workers, schedule rules, sign-in ceremonies, Human accounts, external message batches, peer forwarding, turn workspaces, and site startup. Ankole stores Pages, files, and Brain entries directly as durable content rather than giving them a separate execution lifecycle (see [Pod Content Model](PodContentModel.md), [Files](Files.md), and [BrainV3](BrainV3.md)), and `Connectors` refreshes personal OAuth tokens through the same versioned ceremony rules used for sign-in below (see [Connectors](Connectors.md)).

Whenever a diagram contains two parallel regions, read both regions together at the same instant: a `[when …]` guard on a transition names the state that the companion region must occupy for that transition to fire.

## A Chat Turn

External channel messages and native Pod messages enter the same chat turn pipeline (see [Conversations](Conversations.md), [Signals](Signals.md), and [Sessions](Sessions.md)). When the model finishes a response, the Conversation does not yet contain a public reply: for external channels, Ankole first records an outbound Delivery intent and writes the public Conversation message only after the upstream platform confirms delivery, whereas in Pod Ankole writes the reply directly into the Conversation when the turn ends.

Once an operator suspends a tenant, Ankole closes any queued input that has not yet passed admission without invoking the model (see [Tenants](Tenants.md)). By contrast, turns that were already admitted continue to completion, including turns that pause briefly and retry: when a turn defers for retry, Ankole returns the `Signal` to `queued` while preserving its admission timestamp, which Pod surfaces as `retrying`.

When an input enters `dead_letter`, Ankole posts a system notice in the Conversation rather than a model reply. A turn can also finish normally without posting a new public message. If external delivery stops in `failed` (exhausting automatic retries), `unknown`, or `expired`, Ankole never fabricates a public Conversation message; transient delivery failures that can still retry remain in `Delivery recorded, awaiting confirmation`.

The control plane executes its own built-in tools directly without involving a Worker. Whenever a turn delegates a tool step to a Worker, the control plane commits that completed tool round in PostgreSQL before calling the model again. If a process restarts, Ankole loses only uncommitted in-flight Worker progress and resumes from the stage already recorded in PostgreSQL.

Before an external inbound debounce batch reaches its deadline, `Conversations` has already recorded the observed message while `Signals` has not yet accepted a `Signal`; [An External Message Batch](#an-external-message-batch) covers that earlier window.

```mermaid
---
title: A Chat Turn
---
stateDiagram-v2
  direction LR
  classDef teal fill:#bfe3df,stroke:#3d7a72,color:#12302c
  classDef blue fill:#c3e0ff,stroke:#3d6ea8,color:#10243d
  classDef yellow fill:#f0dcbf,stroke:#a67c3d,color:#3d2c12
  classDef orange fill:#f0d3bf,stroke:#b85a06,color:#4a2a08
  classDef purple fill:#e3d5ff,stroke:#6b4ea3,color:#2a1848
  classDef tan fill:#e5d9ce,stroke:#8a7564,color:#2e261f
  classDef pink fill:#ffcbe6,stroke:#b84d7a,color:#4a1830
  state "Concurrent" as all {
  state "Site" as r0 {
    s0: Starting up
    s1: Tenant active
    s2: Tenant suspended
    [*] --> s0
    s0 --> s1: Site startup completes
    s1 --> s2: Operator suspends tenant
    s2 --> s1: Operator resumes tenant
  }
  --
  state "This turn" as r1 {
    s3: Idle
    s4: Message recorded, turn not started
    s5: Turn running
    s6: Model returned, reply not public yet
    s7: Closed before admission
    s8: Failed, notice posted in Conversation
    s9: Deferred for retry
    s10: Delivery recorded, awaiting confirmation
    s11: Reply in Conversation
    s12: Turn finished with no new reply
    s13: Worker executing step
    s14: Model returned, Worker progress lost
    s15: Delivery stopped, reply absent from Conversation
    [*] --> s3
    s3 --> s4: External message arrives or user posts in Pod [when Tenant active]
    s4 --> s5: Turn starts [when Tenant active]
    s4 --> s7: Closed before admission [when Tenant suspended]
    s5 --> s6: Model finishes response
    s5 --> s8: Turn fails into dead_letter
    s5 --> s9: Turn defers for retry
    s6 --> s5: Control plane completes step, asks model again
    s6 --> s8: Turn fails into dead_letter
    s6 --> s10: Turn ends, records delivery
    s6 --> s12: Turn ends with no new reply
    s6 --> s13: Step delegated to Worker
    s6 --> s11: Turn ends, writes reply to Conversation
    s9 --> s5: Retry resumes
    s9 --> s8: Turn fails into dead_letter
    s10 --> s15: Delivery stops
    s10 --> s11: Platform confirms delivery
    s13 --> s5: Control plane commits round, asks model again
    s13 --> s14: Process restarts
    s14 --> s5: Control plane completes step, asks model again
    s14 --> s8: Turn fails into dead_letter
    s14 --> s10: Turn ends, records delivery
    s14 --> s12: Turn ends with no new reply
    s14 --> s13: Step delegated to Worker
    s14 --> s11: Turn ends, writes reply to Conversation
  }
  }
  class s0 tan
  class s4 blue
  class s5 blue
  class s6 purple
  class s7 orange
  class s8 orange
  class s9 blue
  class s10 pink
  class s11 teal
  class s12 tan
  class s13 yellow
  class s14 orange
  class s15 pink
```

`Closed before admission` covers inputs revoked before a turn starts, whereas `Failed, notice posted in Conversation` covers admitted runs that exhausted retries and entered `dead_letter`. In both states, Ankole records a system notice in the Conversation rather than a model reply.

## Long-Running Work Returning to a Conversation

When a `BackgroundAgentJob` or `Workflow` finishes executing, the Conversation still contains no public reply until the main Session wakes up and relays the outcome (see [BackgroundAgentJob](BackgroundAgentJob.md) and [Workflow](Workflow.md)). If that wakeup `Signal` exhausts retries and enters `dead_letter`, Ankole posts a fallback system notice synthesized from the result stored on the `Signal`. Explicitly stopping the task suppresses both the wakeup relay and the fallback notice.

If a queued Background Agent Job never acquires a ready Worker within its queue deadline, Ankole marks the Job failed before execution ever begins. Once an operator suspends the tenant, queued tasks cannot start, while already running tasks finish their active execution. After a Workflow task calls `sleep`, PostgreSQL holds its progress in committed receipts, so Ankole resumes the task when its deadline arrives even if the tenant is suspended. While a Background Agent Job is waiting for user input (`waiting_on_user`), Worker inactivity timeouts do not mark the Job failed.

Both automatic continuations after completion and manual respawns create a fresh Job row rather than reopening the finished row. If a follow-up message cannot be delivered while a Job is waiting for user input, Ankole emits a separate wakeup notice while keeping the Job in `Waiting for user`. The main Session attaches any output files explicitly during its parent turn.

```mermaid
---
title: How Long-Running Work Returns to a Conversation
---
stateDiagram-v2
  direction LR
  classDef teal fill:#bfe3df,stroke:#3d7a72,color:#12302c
  classDef blue fill:#c3e0ff,stroke:#3d6ea8,color:#10243d
  classDef yellow fill:#f0dcbf,stroke:#a67c3d,color:#3d2c12
  classDef orange fill:#f0d3bf,stroke:#b85a06,color:#4a2a08
  classDef purple fill:#e3d5ff,stroke:#6b4ea3,color:#2a1848
  classDef tan fill:#e5d9ce,stroke:#8a7564,color:#2e261f
  state "Concurrent" as all {
  state "Tenant" as r0 {
    s0: Tenant active
    s1: Tenant suspended
    [*] --> s0
    s0 --> s1: Operator suspends tenant
    s1 --> s0: Operator resumes tenant
  }
  --
  state "Long-running work" as r1 {
    s2: None
    s3: Queued for Worker
    s4: Running
    s5: Succeeded, not yet in Conversation
    s6: Failed, not yet in Conversation
    s7: Sleeping
    s8: Stopped
    s9: Main Session missed wakeup, fallback notice posted
    s10: Waiting for user
    s11: Relayed by main Session
    [*] --> s2
    s2 --> s3: Start a Background Agent Job [when Tenant active]
    s2 --> s4: Start a Workflow [when Tenant active]
    s3 --> s6: Worker never becomes ready
    s3 --> s4: Worker ready, execution starts [when Tenant active]
    s3 --> s8: Caller or operator stops task
    s4 --> s5: Execution succeeds
    s4 --> s6: Execution fails
    s4 --> s7: Task sleeps
    s4 --> s8: Caller or operator stops task
    s5 --> s9: Main Session misses wakeup
    s5 --> s11: Main Session relays outcome
    s6 --> s9: Main Session misses wakeup
    s6 --> s11: Main Session relays outcome
    s4 --> s10: Job asks user a question
    s7 --> s4: Sleep deadline reached, resumes
    s7 --> s6: Fails while sleeping
    s7 --> s8: Caller or operator stops task
    s10 --> s4: User answers [when Tenant active]
    s10 --> s8: Caller or operator stops task
  }
  }
  class s2 teal
  class s3 blue
  class s4 blue
  class s5 purple
  class s6 purple
  class s7 yellow
  class s8 tan
  class s9 orange
  class s10 yellow
  class s11 teal
```

## An Agent's Worker

PostgreSQL maintains one `agent_workers` row per Agent (see [Agent Workers](AgentWorkers.md) and [RuntimeFabric](RuntimeFabric.md)). A Worker enters `Ready` only after its RuntimeFabric channel connects. `AgentWorkers` retains a live transport route only while the Worker is `Ready` or `Draining, connected`. Callers can reserve an execution slot only while the Worker is `Ready`, and a channel disconnect does not release slots that callers have already reserved.

While a Worker is `Starting`, reconciliation retries transient creation failures automatically; the row returns to `Absent` only if the cloud platform explicitly rejects creation or the instance disappears. Once deletion begins (`Deleting`), `AgentWorkers` accepts no further demand. A draining Worker can transition to `Paused` and later resume startup through `Starting`.

```mermaid
---
title: "An Agent's Worker"
---
stateDiagram-v2
  classDef teal fill:#bfe3df,stroke:#3d7a72,color:#12302c
  classDef blue fill:#c3e0ff,stroke:#3d6ea8,color:#10243d
  classDef yellow fill:#f0dcbf,stroke:#a67c3d,color:#3d2c12
  classDef tan fill:#e5d9ce,stroke:#8a7564,color:#2e261f
  s0: Absent
  s1: Deleting
  s2: Starting
  s3: Draining
  s4: Ready
  s5: Draining, connected
  s6: Paused
  s7: Ready, slot reserved
  s8: Disconnected
  [*] --> s0
  s0 --> s1: Begin deletion
  s0 --> s2: Begin creation
  s2 --> s0: Platform rejects creation
  s2 --> s1: Begin deletion
  s2 --> s3: Begin draining
  s2 --> s4: Channel connects
  s2 --> s7: Channel connects
  s3 --> s0: Instance gone
  s3 --> s1: Begin deletion
  s3 --> s6: Pause
  s4 --> s0: Instance gone
  s4 --> s1: Begin deletion
  s4 --> s5: Begin draining
  s4 --> s7: Reserve a slot
  s4 --> s8: Channel disconnects
  s5 --> s0: Instance gone
  s5 --> s1: Begin deletion
  s5 --> s6: Pause
  s6 --> s0: Instance gone
  s6 --> s1: Begin deletion
  s6 --> s2: Resume startup
  s6 --> s3: Begin draining
  s7 --> s0: Instance gone
  s7 --> s4: Release slot
  s7 --> s1: Begin deletion
  s7 --> s5: Begin draining
  s7 --> s8: Channel disconnects
  s8 --> s0: Instance gone
  s8 --> s1: Begin deletion
  s8 --> s3: Begin draining
  s8 --> s4: Channel connects
  s8 --> s7: Channel connects
  class s0 tan
  class s1 tan
  class s2 blue
  class s3 yellow
  class s4 teal
  class s5 yellow
  class s6 yellow
  class s7 teal
  class s8 blue
```

`Starting` transitions directly to `Ready, slot reserved` whenever a Worker resumes from `Paused` while still holding a slot reserved before the pause.

## A Schedule Rule

An automatic cron fire consumes one occurrence from the rule's budget whether it dispatches a `Signal` or exhausts its retry attempts (see [Schedule](Schedule.md)). If the rule cannot fire validly when its slot arrives, Ankole cancels that occurrence, advances the next planned timestamp without deducting from the occurrence budget, and keeps the rule active. `Schedule` skips overdue wakeups outright when a rule is paused, deleted, or already out of occurrences.

One-shot checkbacks and manual cron runs each use a separate `scheduled_events` row with the same four statuses: `scheduled`, `fired`, `cancelled`, and `failed`. Transient dispatch failures keep the row in `scheduled` across early retries and mark it `failed` only on the 10th attempt. A manual run neither consumes the rule's occurrence budget nor advances its next planned timestamp.

```mermaid
---
title: A Schedule Rule
---
stateDiagram-v2
  direction LR
  classDef teal fill:#bfe3df,stroke:#3d7a72,color:#12302c
  classDef yellow fill:#f0dcbf,stroke:#a67c3d,color:#3d2c12
  classDef orange fill:#f0d3bf,stroke:#b85a06,color:#4a2a08
  classDef tan fill:#e5d9ce,stroke:#8a7564,color:#2e261f
  state "Concurrent" as all {
  state "Rule" as r0 {
    s0: Rule active
    s1: Occurrences exhausted
    s2: Rule deleted
    s3: Rule paused
    [*] --> s0
    s0 --> s1: Due and retries exhausted or due and Signal dispatched [when Not due yet]
    s0 --> s2: Delete rule [when Not due yet]
    s0 --> s3: Pause rule [when Not due yet]
    s3 --> s0: Resume rule
    s3 --> s2: Delete rule
  }
  --
  state "This occurrence" as r1 {
    s4: Not due yet
    s5: Occurrence cancelled
    s6: Occurrence failed
    s7: Signal dispatched
    [*] --> s4
    s4 --> s5: Due, rule invalid at slot [when Rule active]
    s4 --> s6: Due, retries exhausted [when Rule active]
    s4 --> s7: Due, Signal dispatched [when Rule active]
    s5 --> s4: Cancelled without spending budget, awaits next slot
  }
  }
  class s2 tan
  class s3 tan
  class s5 yellow
  class s6 orange
  class s7 teal
```

Each dispatched cron fire enters the dedicated `cron:<schedule_id>` execution Session rather than occupying the Session that created the rule.

## A Sign-In Ceremony

Ankole does not pin email verification codes to the browser revision active when the email was sent: even after a user signs out of the entire browser, an unused, unexpired verification code can still complete sign-in (see [Authentication](Authentication.md) and [Browser Sessions](BrowserSessions.md)). External SSO sign-in ceremonies, by contrast, bind to the browser revision captured when the ceremony started; signing out of the entire browser invalidates that in-flight external sign-in.

```mermaid
---
title: A Sign-In Ceremony
---
stateDiagram-v2
  classDef teal fill:#bfe3df,stroke:#3d7a72,color:#12302c
  classDef blue fill:#c3e0ff,stroke:#3d6ea8,color:#10243d
  classDef tan fill:#e5d9ce,stroke:#8a7564,color:#2e261f
  s0: Signed out
  s1: External sign-in pending
  s2: Verification code sent
  s3: Signed in
  s4: Ceremony expired
  s5: Signed out of browser
  s6: Signed out, external sign-in invalidated
  s7: Signed out, verification code still valid
  [*] --> s0
  s0 --> s1: Start external sign-in
  s0 --> s2: Send verification code
  s1 --> s2: Send verification code
  s1 --> s3: External sign-in returns
  s1 --> s4: Expires
  s1 --> s6: Sign out of entire browser
  s2 --> s1: Start external sign-in
  s2 --> s3: Verification code matches
  s2 --> s4: Expires
  s2 --> s7: Sign out of entire browser
  s3 --> s1: Start external sign-in
  s3 --> s2: Send verification code
  s3 --> s5: Sign out of entire browser
  s4 --> s1: Start external sign-in
  s4 --> s2: Send verification code
  s5 --> s1: Start external sign-in
  s5 --> s2: Send verification code
  s6 --> s1: Start external sign-in
  s6 --> s2: Send verification code
  s6 --> s4: Expires
  s7 --> s1: Start external sign-in
  s7 --> s2: Send verification code
  s7 --> s3: Verification code matches
  s7 --> s4: Expires
  class s0 tan
  class s3 teal
  class s5 tan
  class s6 blue
  class s7 blue
```

An external sign-in ceremony completes only when three conditions hold together: the ceremony is unconsumed and unexpired, the browser revision recorded when the ceremony started is at least the browser's latest full-logout revision, and—when the target account is already present in the browser—that account's revision is not newer than the revision at which the ceremony started.

## A Human Account

When an operator suspends a Human account (`suspended` disposition of `disabled`), Ankole retains its bound addresses and contact identifiers so restoring the account reactivates the same Principal with its permissions intact (see [Human Offboarding](HumanOffboarding.md) and [Principal](Principal.md)). When a Human offboards, Ankole releases those addresses and contact identifiers: looking up a released address does not resolve to the departed Human, an offboarded account cannot be restored, and anyone who later claims that address receives a new Principal identity.

Work that has already passed admission continues to completion after either suspension or offboarding, whereas neither a suspended nor an offboarded Human can start new work. When an operator deletes a tenant, Ankole offboards the Humans in that tenant, halts their unstarted work in other tenants, and allows already admitted attempts to finish (see [Tenants](Tenants.md)).

```mermaid
---
title: A Human Account
---
stateDiagram-v2
  classDef teal fill:#bfe3df,stroke:#3d7a72,color:#12302c
  classDef blue fill:#c3e0ff,stroke:#3d6ea8,color:#10243d
  classDef yellow fill:#f0dcbf,stroke:#a67c3d,color:#3d2c12
  classDef orange fill:#f0d3bf,stroke:#b85a06,color:#4a2a08
  s0: Active, no running work
  s1: Offboarded, no running work
  s2: Suspended, no running work
  s3: Active, work in progress
  s4: Active, prior work finished
  s5: Offboarded, work in progress
  s6: Suspended, work in progress
  s7: Offboarded, prior work finished
  s8: Suspended, prior work finished
  [*] --> s0
  s0 --> s1: Human offboards
  s0 --> s2: Operator suspends Human
  s0 --> s3: Start new work
  s2 --> s0: Operator restores Human
  s2 --> s1: Human offboards
  s3 --> s4: Admitted work finishes
  s3 --> s5: Human offboards
  s3 --> s6: Operator suspends Human
  s4 --> s3: Start new work
  s4 --> s7: Human offboards
  s4 --> s8: Operator suspends Human
  s5 --> s7: Admitted work finishes
  s6 --> s3: Operator restores Human
  s6 --> s5: Human offboards
  s6 --> s8: Admitted work finishes
  s8 --> s4: Operator restores Human
  s8 --> s7: Human offboards
  class s0 teal
  class s1 orange
  class s2 yellow
  class s3 blue
  class s4 teal
  class s5 orange
  class s6 yellow
  class s7 orange
  class s8 yellow
```

## An External Message Batch

`Conversations` aggregates rapid external instant messages into a short inbound batch before admitting work (see [Conversations](Conversations.md) and [Signals](Signals.md)). Ankole accepts a `Signal` only when the batch reaches its deadline; if the batch is cancelled before then, Ankole admits nothing. While a batch remains open, upstream message edits update that same batch in place.

```mermaid
---
title: An External Message Batch
---
stateDiagram-v2
  classDef teal fill:#bfe3df,stroke:#3d7a72,color:#12302c
  classDef blue fill:#c3e0ff,stroke:#3d6ea8,color:#10243d
  classDef tan fill:#e5d9ce,stroke:#8a7564,color:#2e261f
  s0: Collecting messages in batch
  s1: Batch cancelled
  s2: Batch accepted
  [*] --> s0
  s0 --> s1: Batch cancelled
  s0 --> s2: Batch deadline reached
  class s0 blue
  class s1 tan
  class s2 teal
```

Native Pod messages bypass inbound batching: Ankole commits the public `Message` and its `Signal` atomically in a single transaction.

## Peer Forwarding

An Agent-to-Agent peer relay chain allows at most six hops (see [Signals](Signals.md) and [Sessions](Sessions.md)). At the sixth hop, Ankole delivers the final receipt back to the originating Agent and rejects any further forwarding. Whenever a Human sends a new message, Ankole starts a fresh hop count from zero. `Sessions` queues ordinary peer messages for their own turn, whereas it allows priority peer messages to steer an active turn.

```mermaid
---
title: Peer Forwarding
---
stateDiagram-v2
  classDef teal fill:#bfe3df,stroke:#3d7a72,color:#12302c
  classDef blue fill:#c3e0ff,stroke:#3d6ea8,color:#10243d
  classDef orange fill:#f0d3bf,stroke:#b85a06,color:#4a2a08
  classDef tan fill:#e5d9ce,stroke:#8a7564,color:#2e261f
  s0: Not forwarded yet
  s1: 1 hop
  s2: 2 hops
  s3: 3 hops
  s4: 4 hops
  s5: 5 hops
  s6: 6th hop, cannot forward further
  s7: Receipt returned to originator
  [*] --> s0
  s0 --> s1: Forward to peer
  s1 --> s0: Human sends a new message
  s1 --> s2: Forward again
  s2 --> s0: Human sends a new message
  s2 --> s3: Forward again
  s3 --> s0: Human sends a new message
  s3 --> s4: Forward again
  s4 --> s0: Human sends a new message
  s4 --> s5: Forward again
  s5 --> s0: Human sends a new message
  s5 --> s6: Forward again
  s6 --> s0: Human sends a new message
  s6 --> s7: Return receipt to originator
  s7 --> s0: Human sends a new message
  class s0 tan
  class s1 blue
  class s2 blue
  class s3 blue
  class s4 blue
  class s5 blue
  class s6 orange
  class s7 teal
```

## A Turn's Worker Workspace

The Session Driver opens a Worker workspace only when the model requests a Worker step (see [Sessions](Sessions.md) and [Agent Workers](AgentWorkers.md)). While the Driver is opening the workspace or waiting for an execution slot, if the current tool round commits or the Worker changes state, the Driver cancels that pending open so the next round can request it cleanly. Once a workspace reaches `Workspace ready`, the Driver keeps it open for the remainder of the turn.

If workspace acquisition times out—or if the Worker is rejected, lacks a provider, or belongs to a disabled Agent—the Session Driver stops waiting for the Worker for the rest of the turn, keeping that unavailable verdict across any later model rounds in the same turn.

```mermaid
---
title: "Whether This Turn Acquires a Worker Workspace"
---
stateDiagram-v2
  classDef teal fill:#bfe3df,stroke:#3d7a72,color:#12302c
  classDef blue fill:#c3e0ff,stroke:#3d6ea8,color:#10243d
  classDef yellow fill:#f0dcbf,stroke:#a67c3d,color:#3d2c12
  classDef orange fill:#f0d3bf,stroke:#b85a06,color:#4a2a08
  classDef tan fill:#e5d9ce,stroke:#8a7564,color:#2e261f
  s0: Not requested yet
  s1: Opening workspace
  s2: Worker unavailable for this turn
  s3: Workspace ready
  s4: Waiting for a slot
  [*] --> s0
  s0 --> s1: Step needs the Worker
  s0 --> s2: Worker cannot run, give up immediately
  s1 --> s0: Worker state changes and retries or round commits and cancels pending open
  s1 --> s2: Acquisition times out
  s1 --> s3: Workspace opened
  s1 --> s4: Worker full, keep waiting
  s3 --> s0: Turn ends, close workspace
  s4 --> s0: Worker state changes and retries or round commits and cancels pending open
  s4 --> s2: Acquisition times out
  s4 --> s3: Workspace opened
  class s0 tan
  class s1 blue
  class s2 orange
  class s3 teal
  class s4 yellow
```

When executing control-plane tools, the Session Driver neither opens a Worker workspace nor pre-warms the Worker.

## Site Startup

The control plane starts its subsystems in strict dependency order and opens the public HTTP and WebSocket endpoint last. None of the earlier startup stages accepts external traffic.

```mermaid
---
title: Site Startup
---
stateDiagram-v2
  classDef teal fill:#bfe3df,stroke:#3d7a72,color:#12302c
  classDef blue fill:#c3e0ff,stroke:#3d6ea8,color:#10243d
  s0: Database starting
  s1: Configuration ready
  s2: Plugins and queues ready
  s3: Gateway and runtimes ready
  s4: Sessions and delivery ready
  s5: Identity sync ready
  s6: Cluster discovery complete
  s7: All subsystems ready, public endpoint closed
  s8: Accepting external traffic
  [*] --> s0
  s0 --> s1: Next supervision group starts
  s1 --> s2: Next supervision group starts
  s2 --> s3: Next supervision group starts
  s3 --> s4: Next supervision group starts
  s4 --> s5: Next supervision group starts
  s5 --> s6: Next supervision group starts
  s6 --> s7: Next supervision group starts
  s7 --> s8: Open public endpoint
  class s0 blue
  class s1 blue
  class s2 blue
  class s3 blue
  class s4 blue
  class s5 blue
  class s6 blue
  class s7 blue
  class s8 teal
```

The actual OTP supervision tree subdivides these stages further: PostgreSQL (`Repo`), the Base shard cluster, and `PubSub` start before `AppConfigure`; observability, initial setup bootstrap, `Oban`, and plugins start before `AIGateway` and `FunctionRuntime`; outbound Delivery, `AgentWorkers`, `Sessions`, and `Workflow` start before the public endpoint opens; and optional startup syncs for external identity providers and the Skill library also finish before the public endpoint opens. Once the public endpoint is open, every backing subsystem is already running.
