# BullX architecture

BullX's core model is a recoverable DAG Workflow with limited streaming I/O at
the Signal Trigger and Action Node boundaries. A run starts from a Signal
Trigger, executes Action Nodes along a directed acyclic graph, and writes enough
execution progress, inputs, outputs, failure reasons, budget consumption, and
human intervention points into PostgreSQL for the Workflow to retry, pause,
resume, and recover after a process restart.

This document fixes only BullX's high-level vocabulary, execution semantics, and
design invariants. Fields, node attributes, storage shapes, providers, runtimes,
adapters, queues, and UI examples in this document illustrate boundaries; they
do not define stable interfaces. Specific schemas, APIs, runtimes, queues,
adapters, policy languages, Skill virtual file systems, Brain storage, sandbox
backends, and UI interactions belong to the corresponding design docs. Those
designs may evolve, but they must not introduce new top-level subjects that
conflict with the invariants in this document.

Some design docs use `Non-goals` to mean "not in this slice," not "never in
BullX"; those local exclusions must still fit the architecture-level vocabulary
and invariants in this document.

## Core judgment

BullX is closer to n8n or Zapier for AI work than to a chat bot framework or a
generic agent runtime. BullX nodes do not only call SaaS APIs. They can also
contain long-running Agents, Skills, sandbox capabilities, SubAgents,
organizational memory, human-in-the-loop work, approvals, policy checks,
streaming interaction, and auditable work loops.

The top-level execution shape is:

```text
Signal Trigger
  -> Workflow DAG
  -> Action Node
  -> checkpoint / recorded result / memory update
```

BullX optimizes for recoverable, explainable, and compensable execution instead
of promising that every external side effect happens exactly once. Nodes that
produce side effects must declare an idempotency, deduplication, or compensation
strategy. The concrete implementation belongs to the node and Capability design
docs.

External systems, timers, webhooks, IM messages, human UI actions, and internal
routing all enter BullX as Signal Triggers. Agentic Loops, SubAgents, external
agent harnesses, transforms, approvals, notifications, external writes,
blackhole branches, and reply actions all enter BullX as Action Nodes. The
system no longer models "who sees the signal, who handles it, and who replies"
as a separate top-level architecture chain. Those concerns should live in the
nodes, edges, and node attributes of the Workflow graph.

## Product lineage

BullX should cover the personal-agent scenarios that Hermes and OpenClaw have
already proven useful, but BullX is not a simple lift of those capabilities into
an enterprise shell. Hermes and OpenClaw let a personal Agent use tools, Skills,
cron, SubAgents, code execution, and message entry points. BullX turns those
capabilities into an organizational work system that is recoverable, auditable,
governed, and able to learn.

The difference comes from a change in the architectural subject.
Hermes/OpenClaw center the core experience on an Agent session. BullX centers
the core durable facts on Workflow runs, Principals, Action Nodes, Budgets,
result records, and Brain. For the same actions, such as "run this every day,"
"delegate to a child Agent," "write code," or "learn a Skill," BullX can answer
additional questions: who authorized the work, how much budget it consumed, what
durable artifact it produced, whether it needed approval, how it recovers after
failure, how the result affects long-term Work, and how the real trajectory
improves the next execution.

The following table maps common Hermes and OpenClaw scenarios to BullX concepts.

| Hermes / OpenClaw scenario | BullX expression |
| --- | --- |
| `SKILL.md` directories, Skill centers, and Agent-created Skills | A Skill is a durable knowledge asset in PostgreSQL and is projected through a virtual file system to preserve the familiar Skill directory experience. |
| Local shell, remote code execution, sandbox, and browser session | Sandbox, browser, messaging, and external API access are atomic Capabilities. Sandbox state is disposable runtime state. The Workflow trusts only durable artifacts, logs, outputs, and checkpoints. |
| SubAgent, delegation, parallel research, and background task | One-off delegation is an ephemeral SubAgent Agentic Loop. Repeated delegation upgrades to a Workflow. The parent Workflow depends only on structured results, status, cost, and an auditable transcript, not on the child Agent's temporary process. |
| ACP / Codex / Claude Code / Gemini CLI harness | An external Agent harness is carried by a SubAgent runtime Capability provider. Codex is one implementation in this runtime family. |
| Cron, scheduled jobs, one-shot reminders, and heartbeat | Time triggers are Signal Triggers. Exact timing, approximate intervals, aggregation checks, SLAs, and deliverable requirements belong to Workflow configuration. |
| Task Flow / background task ledger | A Workflow run is the durable orchestration record. SubAgent runs, sandbox runs, and external harness runs are node/run evidence under the Workflow. The parent Workflow depends on status, structured result, cost, and transcript reference. |
| Trajectory datasets, tool stats, and learning signals | BullX extracts evaluations, preferences, policy improvements, Skill improvements, and future training signals from real Workflow runs, Agentic Loops, tool calls, approvals, result records, and KPI signals. |

This mapping has one core tradeoff. The session, cron, heartbeat, SubAgent, and
Skill file structures that Hermes/OpenClaw expose for personal-agent usability
can keep a similar user experience in BullX, but durable truth must return to
PostgreSQL, Workflow runs, Principal permissions, Budgets, result records, and
audit records.

## Core concepts

BullX should keep its high-level concepts small and stable. Each concept must
explain product behavior rather than pre-commit BullX to a specific table or
supervision tree.

| Concept | Meaning |
| --- | --- |
| Installation | One BullX deployment and its single operating domain. BullX can serve an enterprise, a team, or an OPC operator, but it does not default to SaaS multi-tenancy as the product boundary. |
| Principal | An internal subject that can be authorized, audited, and held responsible. Humans, AI Agents, services, and system actors are all Principals. |
| Connected Realm | An external identity and event space connected to BullX, such as a Feishu tenant, Slack workspace, GitHub org, or CRM workspace. It is not a BullX tenant. |
| Workflow | A recoverable DAG composed of Signal Triggers and Action Nodes. A Workflow describes cross-node dependencies and is the execution skeleton. |
| Signal Trigger | The entry point into a Workflow. Adapters, webhooks, time triggers, routing, and human triggers are all modeled as Signal Triggers. |
| Action Node | A recoverable execution contract inside a Workflow. Non-AI behavior is also an Action Node, not an Agent. |
| Agent | A digital work subject with AI work capability. When an Agent runs inside a Workflow, it is one kind of Action Node, but it has its own identity, memory, responsibilities, permissions, and KPIs. |
| Agentic Loop | One reasoning and tool-use loop of an Agent. It can run as an Action Node inside a Workflow or as the execution body of a one-off SubAgent. |
| Capability | A governed atomic ability that an Action Node may call, such as a model, tool, browser, sandbox, messaging channel, or external API. External Agent harnesses are exposed as callable abilities through SubAgent runtime Capability providers. |
| Skill | A procedural knowledge asset that an Agent can read and use. A Skill can teach an Agent how to call a Capability, but it does not grant execution power. |
| SubAgent | A child Agentic Loop run derived by an Agent or Workflow to isolate context, do parallel work, or call an external Agent harness runtime. |
| Human-in-the-loop | A participation pattern in which a human joins the Workflow as a Principal. It is not a Capability. It usually appears as a human task, approval, or policy-gate Action Node. |
| Work | A durable work responsibility that persists across Workflow runs. A Workflow run is one execution that may create, advance, pause, resume, or complete Work. |
| Budget | A governance constraint over tokens, model cost, runtime, tool calls, external spending, or quota. A Budget can produce a hard stop, degradation, queuing, or over-budget approval. |
| Brain | BullX's long-term memory and reasoning world model. Brain durable truth remains in PostgreSQL. Brain forms evolvable memory from Workflows, Agent interactions, external events, and execution results. |

The most important change is that Agent no longer means every executable
subject. A deterministic transform, approval node, notification node, CRM write
node, or blackhole branch is not an Agent. It is only an Action Node. Only a
digital work subject with AI reasoning, memory, and a responsibility boundary is
an Agent.

## Workflow is the system skeleton

Workflow is the unit in which BullX executes real work. A Workflow describes
what triggered the work, which nodes execute under which dependencies, which
nodes support streaming input or output, where human or policy gates appear,
where execution terminates, and how results are recorded.

BullX Workflows must satisfy these constraints:

- A Workflow is a DAG, not a linear chat session.
- A Workflow can pause, resume, retry, and rebuild from durable checkpoints.
- Nodes pass structured inputs, outputs, and metadata rather than scattering
  temporary process state.
- Streaming is an I/O delivery mode at the Signal Trigger and Action Node
  boundaries. It is not a global Workflow execution mode.
- Child execution bodies can run in parallel, but the parent Workflow can depend
  only on child status, structured results, cost, and transcript references.
- Exact timers, approximate intervals, webhooks, and human triggers decide only
  when a Workflow starts. They do not change Workflow execution semantics.
- Reliability comes from checkpoints, retries, idempotent node contracts,
  compensation, and operator recovery. BullX does not promise that every node
  executes only once in every failure scenario.

The Workflow DAG describes recoverable dependencies across nodes. A node can
contain internal loops, conversations, tool calls, streaming generation, or
external runtime execution, but those internal processes expose only
checkpoints, status, structured output, artifacts, cost, and failure reasons at
the node boundary. An Agentic Loop is internal Action Node execution semantics;
it does not change the DAG nature of the Workflow graph.

Workflow edges express logical dependency and value passing. Streaming only
describes whether a value can be delivered incrementally before it is fully
materialized. In the current BullX context, streaming mainly means LLM
progressive response or token streaming for UI display, interactive replies, log
display, or a small number of downstream nodes that support streaming input. A
Signal Trigger can produce materialized input or streaming input. An Action Node
declares whether it supports streaming input and streaming output. If a
streaming payload goes to an Action Node that does not support streaming input,
BullX first materializes or buffers it into complete input. If an Action Node
supports streaming output but its downstream node does not support streaming
input, the downstream node receives only the materialized final output.

Workflow edges do not need to express every organizational meaning. Complex
semantics should land in node types and node attributes where possible, so the
execution graph remains inspectable, recoverable, and explainable.

## Signal Trigger

A Signal Trigger is the entry point into a Workflow. It converts something that
happened outside or inside BullX into trigger input that a Workflow can consume.

Common Signal Triggers include:

- IM messages.
- Webhooks.
- Time triggers.
- External system events.
- Human UI actions.
- Internal routing results.
- Output from another Workflow.

A Signal Trigger has one important attribute: `bidirectional`. When
`bidirectional=true`, the Workflow graph can use a special `Reply to Trigger`
Action Node. This node represents a direct reply to the trigger source, such as
replying to the original IM conversation or interaction request. `Reply to
Trigger` is always `sink=true`.

When `bidirectional=false`, the Workflow can still send notifications, record
facts, write to external systems, or create Work, but it cannot use the special
`Reply to Trigger` node. If the Workflow needs to notify the external world, it
should use an ordinary Action Node, such as "send a direct message," "create a
ticket," or "write a CRM note."

Time triggers are Signal Triggers. Cron, one-shot reminders, intervals, and
heartbeats differ through Workflow configuration: whether the trigger time is
exact, whether the run aggregates multiple lightweight checks, whether it
declares an SLA, whether it produces an auditable deliverable, and whether it
enters a no-op sink when nothing changed. A heartbeat should not prove that a
resident Agent is running. It is only a Workflow run started by time.

## Action Node

An Action Node is one recoverable execution contract inside a Workflow. It can
be AI reasoning, deterministic logic, a human task, a human approval, an
external API call, message sending, data transformation, waiting, branch merge,
or blackhole termination.

Action Node, Capability, and Skill have a three-layer boundary. An Action Node
expresses one execution inside a Workflow. A Capability is a governed ability
that an Action Node can call. A Skill is procedural knowledge that teaches an
Agent how to use an ability. For example, "write a CRM note" is an Action Node.
It calls a CRM external API Capability. If an Agent needs to learn when and how
to write CRM notes, the Agent can read the relevant Skill.

Every Action Node needs to express at least five high-level categories:

1. Contract: inputs, outputs, result states, and error semantics.
2. Execution binding: whether deterministic logic, an Agent, a Capability, a
   SubAgent runtime, a human task, or an external integration executes it.
3. Governance: which Principal permission it needs, which Budget it consumes,
   and whether it triggers a policy gate or approval.
4. Effect: whether it has external side effects and how it handles retry,
   idempotency, deduplication, compensation, and audit.
5. Lifecycle: whether it supports streaming, pause/resume, timeout, sink, human
   handoff, and recovery.

`sink=true` means that the node terminates the current branch. No downstream
Action Node may be attached after any `sink=true` node. Blackhole is not a
special routing result. It is a `sink=true` Action Node that explicitly means
"this branch ends here and produces no further actions."

## Agent

An Agent is a digital work subject with AI work capability, long-term memory,
responsibility boundaries, permission boundaries, outbound identity, and KPIs.
When an Agent runs inside a Workflow, it appears as one kind of Action Node, but
it is not an alias for ordinary Action Nodes or for a single LLM loop.

An Agent should answer these questions:

- What long-term goal or KPI does it serve?
- What Work can it create or advance?
- Which models, providers, integrations, or downstream Action Nodes can it call?
- Which Skills can it read?
- Which Capabilities and SubAgent runtimes can it use?
- Which Agent Principal does it execute as, and does this execution have
  triggering, authorizing, approving, or acting-on-behalf-of relationships?
- How do token, cost, runtime, and tool-call Budgets constrain it?
- Which Workflow inputs can it see?
- Can its output be delivered as a stream?
- How does its result enter Brain and KPI evaluation?

Non-AI nodes should not be called Agents to give them a sense of agency. If a
non-AI node needs an independent audit identity, model it with a Service
Principal or System Principal instead of modeling it as a non-AI Agent.

An Agent usually has its own Agent Principal. One Agent Node execution should
also record the triggering Principal, authorizing or approving Principal, and
acting-on-behalf-of relationships. Agent identity and delegated authorization
must not collapse into one indistinguishable subject.

## Skills and the virtual file system

BullX supports Skills, but Skill durable truth lives in PostgreSQL. Each Skill
should have ownership, visibility, versioning, compatibility, review/policy
metadata, and content assets. Specific schemas, the VFS mutation protocol,
review state machines, and Skill Hub implementation belong to the Skill design
doc. This architecture document constrains only the boundary.

To preserve the usage habits already formed by Hermes and OpenClaw, BullX
projects database-backed Skills into a virtual file system. Any execution
subject with Skill read permission, including an Agent, a derived SubAgent
internal execution body, code running in a sandbox, or import/export tooling,
can see a structure like this:

```text
skills/
  customer-risk/
    SKILL.md
    references/
    templates/
    scripts/
```

This file tree is a projection, not a durable source. When something writes to
the virtual file system, BullX should translate the change into a database
mutation, version record, permission check, and audit event. When something
reads from the virtual file system, BullX should filter visible Skills by Agent,
Workflow, Principal, Connected Realm, platform compatibility, and policy.

A Skill can contain scripts, templates, or example code as passive assets.
Executing those assets must go through a governed Capability or Action Node. A
Skill itself provides knowledge and materials. It does not grant execution
power, and it does not directly produce external side effects. Shell, browser,
API, message-sending, and external mutation execution still belong to governed
Capabilities or Action Nodes. This boundary lets BullX keep the low-friction
`SKILL.md` experience without hiding execution power inside prompt files.

## Capability and SubAgent runtime

A Capability is an atomic ability that an Action Node may call. Models, tools,
browsers, sandboxes, messaging channels, and external APIs are Capabilities.
Approval is not a Capability; it is Action Node or policy-gate semantics. This
keeps Capability as the atomic boundary for "what can be done" while Action
Node owns "when to do it, who does it, whether to wait for approval, and how to
record the result."

A SubAgent runtime is a Capability provider that carries child Agentic Loop
runs. A SubAgent Action Node declares the task, policy, budget, timeout, result
schema, and handoff inside the Workflow. It calls the SubAgent runtime
Capability, creates a child Agentic Loop run, and returns structured result,
status, cost, and transcript reference to the parent Workflow. This boundary
avoids flattening a full Agent runtime into an ordinary tool and avoids
promoting Codex, Claude Code, Gemini CLI, or ACP harnesses into new top-level
objects.

Sandbox-like Capabilities can run code, shell commands, browsers, tests, data
analysis, or external harnesses, but sandbox processes, temporary files, and
browser tabs are disposable state. The Workflow treats only explicitly recorded
artifacts, logs, stdout, stderr, patches, tool results, costs, and checkpoints
as durable facts.

A SubAgent is a child Agentic Loop that isolates context. A parent Agent or
Workflow can delegate a bounded task to a SubAgent and specify model, Skills,
tool policy, sandbox policy, budget, timeout, fan-out limit, result schema, and
handoff channel. The parent Workflow should not poll the child Agent's private
context to advance the main flow. The parent Workflow should wait for the child
execution body to produce a status change, structured result, failure reason, or
timeout record.

The durability of a delegation pattern depends on product semantics. The
SubAgent itself is always an Agentic Loop with isolated context:

- If the user only needs temporary parallel research, code inspection,
  experiments, or material organization in the current task, BullX uses a
  one-off ephemeral SubAgent Agentic Loop. The system can still record the
  transcript, tool calls, budget, and final result, but it does not create a
  reusable Workflow definition.
- If the user wants the same delegation to run repeatedly, such as daily market
  monitoring, weekly PR audits, hourly customer-risk scans, or a fixed
  multi-Agent research flow, BullX should model it as a Workflow. Schedule,
  input, Skills, budget, approval, delivery, and retry then belong to the
  Workflow definition.

Codex is one implementation of the SubAgent runtime. BullX does not need to make
Codex a new top-level object. Codex is a child Agent called by a SubAgent Action
Node, constrained by sandbox and tool policy, managed by budget, and recorded by
the Workflow. Codex can handle repository edits, tests, code review, or
migration work. BullX owns identity, authorization, runtime boundaries, result
archival, and later approval.

## Time-triggered Workflows

The cron jobs, scheduled tasks, one-shot reminders, and heartbeats from Hermes
and OpenClaw all land in Workflow in BullX. They are not parallel top-level
concepts. A time Signal Trigger starts a Workflow run, and Workflow
configuration decides exact timing, approximate intervals, aggregation checks,
SLAs, delivery, no-op sinks, Work updates, or Brain ingestion.

A background task ledger is not an orchestration system. SubAgent runs, external
Agent harness runs, sandbox runs, and isolated executions can all have run
records, but when the behavior needs multi-step dependencies, retries,
approvals, delivery, or long-term reuse, the real orchestration object should be
a Workflow.

A Workflow can contain SubAgent Action Nodes. The Agentic Loop inside a SubAgent
node can continue to derive child SubAgents. Those derivations happen inside the
Action Node and do not add new nodes to the parent Workflow graph. Fan-out,
nesting depth, concurrency, timeout, tool surface, and budget are governance
inputs. The default design should limit recursive delegation so an Agent cannot
use child Agents to bypass its own permission, budget, or approval boundaries.

## Principal and identity

Principal is the internal identity root. Humans, AI Agents, services, and system
actors can all be Principals because all of them may be authorized, audited,
have permissions revoked, or carry responsibility.

Connected Realms provide external identity and event spaces, but they do not own
BullX identity. Feishu, Slack, Discord, GitHub, Google, CRM systems, and similar
systems can provide login assertions, external actors, event provenance, or
outbound credentials. BullX AuthN/AuthZ maps those external proofs to internal
Principals.

This boundary creates several principles:

- An external account is not a BullX user.
- An Adapter does not own identity; it only provides identity or event evidence.
- A Web session belongs to an internal Human Principal.
- An AI Agent can have its own Agent Principal.
- If a non-AI Action Node needs independent permission, it should use a Service
  Principal or System Principal.
- Audit records should explain which Principal triggered, approved, executed,
  or acted on behalf of another subject for an action.

The Principal represented by an Agent is first the Agent's own Agent Principal.
If one execution acts on behalf of a Human, service, team, or external account,
the execution should record the triggering Principal, authorizing or approving
Principal, and acting-on-behalf-of relationship as separate audit facts instead
of merging them into one subject field.

## Human-in-the-loop

BullX must model human-in-the-loop as a Workflow participation pattern instead
of hiding human intervention in chat side channels, background notes, or
unrecoverable temporary state. Humans can approve, add context, correct AI
conclusions, take over execution, escalate risk, or confirm final results inside
a Workflow.

Human Task / Approval Node is a family of Action Nodes. A human participates as
a Principal and provides approval, supplemental input, correction, takeover,
escalation, or final confirmation inside a Workflow. A human task Action Node
can pause the Workflow, notify the target Human Principal or group, wait for
structured input, and resume execution from a durable checkpoint after the input
is submitted. The node output becomes ordinary input for downstream Action
Nodes, so later execution, audit, failure recovery, and Brain ingestion can all
see the fact of human participation.

Human-in-the-loop does not only serve high-risk approval. It also supports
low-risk cases that still need human judgment, such as adding missing materials,
choosing among candidates, confirming customer tone, correcting an Agent's
misjudgment, or choosing among multiple follow-up paths. Node configuration and
policy gates should decide the difference, not ad hoc runtime convention.

## Governed external actions

External actions should be expressed explicitly by Action Nodes instead of being
hidden in Agent prompts, provider SDKs, or free tool calls. An Action Node that
produces side effects needs clear inputs, outputs, permissions, cost, risk, and
audit boundaries.

High-risk external actions should not be executed directly by AI Agent nodes.
Customer-facing, financial, legal, data deletion, contract, payment, and
permission-changing actions should pass through an explicit approval or
policy-gate Action Node in the Workflow graph before entering the Action Node
that produces the side effect. This representation is easier to inspect,
recover, and audit than hiding safety logic in a prompt, adapter, or provider
SDK.

Budget is also part of governance. BullX should support token budgets, model
costs, runtimes, external API spend, and tool-call limits by Installation,
Principal, Agent, Workflow, Action Node, Capability, and SubAgent. When a budget
is exceeded, the system should explicitly choose a hard stop, degraded model,
queueing, human approval request, or supplemental Work. It must not rely only on
prompt text that asks an Agent to "save tokens."

## Work and Workflow runs

Workflow owns execution. Work expresses durable responsibility. Work can persist
across many Workflow runs. A Workflow run is one execution that may create,
advance, pause, resume, or complete Work.

Long-term goals remain important, but this high-level document does not need to
extract them into a separate term. The key boundary is that one Workflow run
must not be mistaken for the whole work responsibility. The value of an Agent is
that it can keep advancing Work and improve later behavior from execution
results.

## Brain and memory

Brain is BullX's long-term memory and reasoning world model. It is not only a
log, and it is not a simple vector store. Brain is a logical-layer concept. Its
physical durable truth still lives in PostgreSQL. Brain should extract evolvable
objects, relationships, perspectives, and experiences from Agent conversations,
Workflow inputs, external events, Action Node outputs, and execution results.

Brain should not replace Workflow. Workflow owns execution and recovery. Brain
lets Agents act with better context and experience in later Workflows.

Workflow run and Agentic Loop transcripts also form real execution facts. BullX
can extract evaluations, preferences, policy improvements, Skill improvements,
and future training signals from durable execution facts that are constrained by
permissions, privacy, and redaction. The trajectory / learning design doc owns
the specific data formats, export process, training uses, and privacy policy.

The high-level relationship is:

```text
Workflow execution
  -> Action Node inputs / outputs / results
  -> Brain ingestion and consolidation
  -> Better future Agent behavior
```

## Typical user stories

### Listening in a group chat without speaking

An IM Signal Trigger starts a Workflow from a customer group message. A risk
detection node determines that the message concerns a customer budget freeze.
`CustomerSuccessAgent`, as an AI Agent Action Node, analyzes context and creates
or updates customer-risk Work. An ordinary messaging Action Node privately
notifies the responsible owner. The group does not need a reply, so the Workflow
does not use `Reply to Trigger`.

### One trigger starts multiple branches

One external event can fan out into multiple branches. The customer-risk branch
enters `CustomerSuccessAgent`, the financial-risk branch enters `FinanceAgent`,
and a completely unrelated branch enters a blackhole Sink Action Node. This
model does not need to make "distribution" an independent center. The Workflow
graph itself expresses branching and termination.

### Streamable AI experience

An Agent node can declare `streaming_output=true`, and a downstream node can
declare `streaming_input=true`. The Agent Node's logical output is still the
complete reply text or structured result. Streaming only delivers tokens or
chunks incrementally before the final output is materialized. If the trigger
source allows direct replies, the Workflow can connect streaming output to
`Reply to Trigger`. If the downstream node does not support streaming input,
BullX materializes the complete output before delivery.

### High-risk actions need a gate

An Agent can suggest sending a quote explanation to a customer, but it cannot
write the outbound message directly. The Workflow first enters a policy-gate or
human approval Action Node. If the gate approves, the real outbound Action Node
executes. If the gate rejects, the Workflow records the result and may notify
the owner or create supplemental Work.

### Human supplementation, correction, and takeover

An Agent node may discover insufficient context, low confidence, or action risk
that exceeds the automation boundary. The Workflow can enter a human task Action
Node and ask the responsible owner to add materials, edit a draft, choose the
next path, or take over execution. After the human submits input, the Workflow
continues from the checkpoint instead of losing context and starting over.

### Research Agent combines memory and external events

A research Agent can use user conversations, market events, historical
conclusions, and external data sources as Workflow inputs. Brain turns those
inputs into retrievable and evolvable memory. Later Workflows let the Agent read
Brain context instead of only searching raw chat logs.

### Skills drive reusable ability

An operations Agent needs to handle customer renewal risk. It can read the
`customer-risk` Skill. The virtual file system exposes `SKILL.md`, templates,
and reference materials. The Agent uses the Skill to generate analysis and
recommendations. If the work needs to write CRM, send a message, or run code,
the Workflow still enters the corresponding Action Node. That node calls the
governed Capability and remains constrained by permissions, budget, and
approval.

### Exact scheduling becomes a Workflow

A user asks, "send me a customer-risk daily report every morning at 9." BullX
creates a time Signal Trigger with exact schedule configuration and a daily
report Workflow. The Workflow can read Brain, CRM, yesterday's group-chat
Signals, and unfinished Work, call an Agent to generate a summary, and deliver
it through a messaging Action Node. Run records, failures, budgets, and outputs
belong to the Workflow run, not to an independent cron log.

### Periodic awareness is also a time-triggered Workflow

A user asks an Agent to check for urgent items every 30 minutes. BullX uses an
interval time trigger to start an awareness Workflow. This Workflow checks the
inbox, calendar, child-task status, and high-priority Work. If nothing changed,
the Workflow enters a no-op sink. If something changed, the Workflow creates
Work or notifies the responsible owner. When the behavior needs exact timing,
long analysis, or repeated deliverables, the same time trigger can become a
scheduled Workflow with an SLA and delivery target.

### Parallel research and one-off SubAgents

A main Agent needs to research three competitors at the same time. It can derive
three ephemeral SubAgents, each with separate context, Skills, sandbox, budget,
and timeout. The parent Workflow waits only for three structured results and
then continues by merging them. If "weekly competitor research" becomes a
stable requirement, this SubAgent orchestration should become a Workflow.

### External Agent harness as child Agent

A user asks in chat, "fix the failing tests in this repo." BullX calls a
code-oriented external Agent harness runtime through a SubAgent Action Node and
gives it a controlled workspace, tool policy, budget, and timeout. This child
Agent can modify code and run tests, but external publishing, merging,
deployment, or high-risk credential access still requires a policy gate or
human approval in the Workflow. The parent Workflow records the patch, test
output, cost, and final status.

## Non-goals

This document does not define:

- Specific database schemas.
- Specific queues, workers, supervisors, or runtime modules.
- A specific adapter list.
- A specific Workflow DSL or UI canvas format.
- A specific approval policy language.
- Specific Skill table structures, Skill VFS protocol, or Skill Hub
  implementation.
- A specific sandbox backend, external Agent harness adapter, SubAgent queue, or
  thread-binding implementation.
- A specific token billing model, budget approval UI, or quota settlement
  system.
- Specific trajectory / learning data formats, export processes, training uses,
  or privacy policies.
- A specific Brain storage model.
- A SaaS multi-tenant isolation model.

If later design docs need these details, they should expand the workflow-first
vocabulary from this document instead of restoring the old top-level model.

## Design invariants

- PostgreSQL is the durable fact source.
- Process-local state must be reconstructible.
- Workflow is a recoverable DAG, not a linear chat session.
- A Workflow DAG describes cross-node dependencies. Loops inside an
  Agentic Loop, SubAgent runtime, or external runtime do not change the DAG
  nature of the graph.
- Adapters, webhooks, time triggers, and routing are all Signal Triggers.
- Cron, one-shot reminders, and heartbeats start Workflow runs through Signal
  Triggers. They are not parallel top-level runtimes.
- Non-AI execution logic is an Action Node, not an Agent.
- An Action Node with `sink=true` terminates the current branch.
- `Reply to Trigger` exists only for a Signal Trigger with
  `bidirectional=true`, and it is always a sink.
- Streaming input/output is a delivery mode at the Signal Trigger and Action
  Node boundaries. It is not a global mode, independent topology, or general
  stream-processing semantic.
- An Action Node is one recoverable execution contract in a Workflow. A
  Capability is a governed ability that an Action Node may call. A Skill is
  procedural knowledge and materials.
- Skill durable truth lives in PostgreSQL. The file tree is only a virtual file
  system projection.
- A Skill can contain passive assets, but it does not grant execution power.
  Executing scripts, templates, or example code must go through a governed
  Capability or Action Node.
- Sandbox Capability runtime state is ephemeral. Only explicitly recorded
  artifacts, outputs, logs, patches, checkpoints, and results are durable facts.
- A one-off SubAgent is an ephemeral Agentic Loop. Repeated SubAgent
  orchestration should become a Workflow.
- External Agent harnesses are carried by SubAgent runtime Capability providers.
  They are not new top-level architectural subjects.
- Human-in-the-loop is a Workflow participation pattern. It usually appears as a
  human task, approval, or policy-gate Action Node and must be pausable,
  resumable, and auditable.
- High-risk external side effects must pass through explicit approval or a
  policy-gate Action Node.
- Token Budgets, cost quotas, and over-budget approval belong to governance.
  They must not exist only in prompt text.
- Brain durable truth still lives in PostgreSQL.
- Trajectories and learning signals can only be based on durable execution facts
  constrained by permissions, privacy, and redaction.
- Reliability should use checkpoints, retries, idempotency, deduplication,
  compensation, and operator recovery. BullX does not promise that every node
  executes only once in every failure scenario.
- Important behavior must be auditable, explainable, and recoverable.

## How later designs use this document

Later design docs should treat this document as a vocabulary and direction
constraint, not as an implementation manual.

When a design describes an external entry point, it should first ask: which kind
of Signal Trigger is this, and is it `bidirectional`? When a design describes
execution logic, it should first ask: which kind of Action Node is this, which
Capabilities or SubAgent runtimes does it call, does it support streaming input
or output, and is it `sink=true`? When a design describes an AI subject, it
should first ask: what are this Agent's long-term goals, Work, Agent Principal,
memory, KPIs, Skills, Capabilities, Budget, and callable node boundaries?

An implementation can temporarily cover only a small slice, but it should not
introduce permanent concepts that contradict these high-level constraints.

## One sentence

BullX is an AgentOS for long-running digital work: it uses recoverable DAG
Workflows to carry execution; Signal Triggers to connect to the world; Action
Nodes to express work steps, external side effects, Skills, sandboxes,
SubAgents, and human-in-the-loop participation; Agents to carry intelligent
responsibility; Principals, Budgets, and node constraints to control permission
and cost; a PostgreSQL-backed Brain to accumulate memory; and real execution
facts to drive continuous improvement.
