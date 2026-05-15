# BullX architecture

BullX's core model is reactive process choreography executed as bounded,
stateless Segments, where the identity of any cross-Segment business process
is reconstructed structurally from domain state rather than held by the
engine. A Workflow describes how the system should respond to domain events.
Each incoming Signal that matches a Catch attribute on some Node starts one
Segment, the Segment activates Nodes along outgoing edges until all active
branches resolve, and the engine makes no commitment about whether or when
subsequent Segments will continue the same business process. Continuity
across Segments is the domain layer's responsibility, expressed by references
among durable domain objects.

This document fixes only BullX's high-level vocabulary, execution semantics,
and design invariants. Fields, node attributes, storage shapes, providers,
runtimes, adapters, queues, and UI examples illustrate boundaries; they do not
define stable interfaces. Specific schemas, APIs, runtimes, queues, adapters,
policy languages, Skill virtual file systems, Brain storage, sandbox backends,
and UI interactions belong to the corresponding design docs. Those designs may
evolve, but they must not introduce new top-level subjects that conflict with
the invariants in this document.

Some design docs use `Non-goals` to mean "not in this slice," not "never in
BullX"; those local exclusions must still fit the architecture-level vocabulary
and invariants in this document.

## Core judgment

BullX sits between two established styles of system and is not a member of
either.

On one side, IM-native agent frameworks like Hermes and OpenClaw center on an
Agent session and have no Workflow abstraction. The session does the work; the
session also carries the durable trace. There is no separable graph that
describes how the system reacts across many events.

On the other side, automation workflow engines like n8n, Activepieces, Dify,
Camunda, and Temporal treat a workflow as something the user launches and
expects to complete. The engine holds a stateful Run or Process Instance that
must survive pauses, restarts, and external waits; the user observes that Run
to know whether the work happened.

BullX is closer in abstraction to BPMN than to either side: it accepts
multiple entry points into the same graph, allows intermediate event catches,
correlates incoming events to in-flight processes by domain identity, and
makes human participation a first-class Workflow pattern. But the BPMN engine
tradition (Camunda, Activiti, Flowable) keeps a stateful Process Instance
that the engine owns, which BullX does not. BullX shifts that responsibility
into the domain layer.

The top-level shape of one execution is:

```text
Signal arrives matching a Catch attribute on some Node
  -> Segment activates Nodes along outgoing edges
  -> all active branches resolve at Sink positions, failure, or contract boundary
  -> domain object writes and recovery points record what happened
```

BullX optimizes for recoverable, explainable, and compensable execution
instead of promising that every external side effect happens exactly once.
Nodes that produce side effects must declare an idempotency, deduplication,
or compensation strategy. The concrete implementation belongs to the node and
Capability design docs.

## Process model

This section is load-bearing for the rest of the document. The vocabulary
that follows depends on these four ideas being held simultaneously.

**1. Workflow is a process definition, not a task.** A Workflow describes how
the system should respond to domain events. It is not "an automation the user
launches and waits for." Users do not start Workflows the way they start a
Zapier zap or a Dify run; they do other things (send IM messages, file issues,
click approval buttons), and BullX uses Workflows to describe how the system
reacts. Workflows do not "complete" or "fail" as wholes — only individual
Segments succeed or fail.

**2. Segment is the execution unit.** When a Signal matches a Catch attribute
on some Node inside some Workflow, the engine executes one Segment: a
stateless execution wave. It starts from the matched Catch, activates Nodes
along outgoing edges, and ends when all active branches have reached Sink
positions, failed, or otherwise resolved according to the Segment contract. A
Sink position terminates one branch: it is either a Node with no outgoing
edges, or a Catch-bearing Node reached through an incoming edge. The matched
Catch itself is not a Sink for the Segment that starts there. The engine makes
no commitment about Segments coming after this one — they may follow, they may
not, they may follow much later from a different external Signal. Segment is
the only Workflow execution unit in this document.

**3. Structural process identity is typed, not engine-owned.** A business
process across Segments — for example, "the lifecycle of GitHub issue #123
through classification, ticket creation, approval, and PR" — is a real
concept. It corresponds to what BPMN engines call a Process Instance, but
BullX does not assign an engine-owned instance ID and does not hold that
state in the engine. The identity is formed only by designated typed causal
or correlation references among domain objects, not by arbitrary foreign keys
or incidental object links: issue #123 references ticket T456, ticket T456
references approval A789, approval A789 references PR P012. If you have the
chain, you have the business process identity. The same chain seen by two
different Segments is the same process; a different chain is a different
process. There is no separate engine-side identity to keep in sync.

**4. The engine is a stateless Segment executor.** BEAM processes that execute
Segments hold no cross-Segment state. Engine state during a Segment is
reconstructible from the external substrate selected by the Segment's runtime
contract and is discarded when the Segment terminates. The durable layer is
the domain layer: Workflow definitions, Principal and Budget records, Work,
Skills, Brain, conversation and message records, approval records, and
side-effect outcomes — these are the committed product facts. Engine
internals such as in-flight Segment state, Signal buffers, intermediate
stream chunks, and node-internal scratch state are not durable truth. No
transient Node output crosses a Catch boundary; data needed after a Wait or
intermediate Catch must be committed as product facts before the earlier
Segment terminates.

Together: BullX is **reactive process choreography with structural process
identity, executed as stateless Segments over BPMN-shaped acyclic graphs**.
The rest of this document uses this vocabulary consistently.

## Recovery, persistence, and audit scope

Recoverable in BullX means the runtime can survive BEAM process loss by
reconstructing the next safe step from the external state that the owning
Segment's runtime contract chose to keep. It does not mean Workflow is a
durable engine, that Segments persist across restarts as live entities, or
that every intermediate event is durably logged.

PostgreSQL is the source of truth for committed product facts: Workflow
definitions, Segment outcomes that must survive restart, Principal
authorization and approval evidence, Work and Brain mutations, Budget and
cost records, conversation and message records, and externally visible
side-effect outcomes when the node contract requires them. Redis, PubSub,
unlogged PostgreSQL tables, ETS projections, provider state, and process-local
state are valid substrates for Signal delivery, buffering, caches, and runtime
coordination when loss before an accepted boundary is within the contract.
The Segment executor itself can use unlogged state because Segments do not
need to survive PostgreSQL restart — only the domain object writes they
produce do.

The audit invariant is product-level. It applies to Agent decisions that
affect Work, approvals and policy-gate outcomes, Principal delegation,
high-risk external side effects, committed artifacts, and other facts an
operator needs in order to explain or recover business behavior. It is not a
blanket requirement to persist every data-processing step inside a Signal,
Segment, Agentic Loop, stream, or routing path.

## Product lineage

BullX should cover the personal-agent scenarios that Hermes and OpenClaw have
already proven useful, but BullX is not a simple lift of those capabilities
into an enterprise shell. Hermes and OpenClaw let a personal Agent use tools,
Skills, cron, SubAgents, code execution, and message entry points. BullX
turns those capabilities into an organizational work system that is
recoverable, auditable, governed, and able to learn.

The difference comes from a change in architectural subject. Hermes and
OpenClaw center the core experience on an Agent session. BullX centers the
core product facts on Workflow definitions, Segments, Principals, Budgets,
domain object records, recorded Node outcomes, and Brain. For the same
actions — "run this every day," "delegate to a child Agent," "write code,"
"learn a Skill" — BullX answers additional questions: who authorized the
work, how much budget it consumed, what recorded artifact it produced,
whether it needed approval, how it recovers after failure, how the result
affects long-term Work, and how the real trajectory improves the next
execution.

| Hermes / OpenClaw scenario | BullX expression |
| --- | --- |
| `SKILL.md` directories, Skill centers, Agent-created Skills | Skill is a durable knowledge asset in PostgreSQL, projected through a virtual file system to preserve the familiar directory experience. |
| Local shell, remote code execution, sandbox, browser session | Sandbox, browser, messaging, and external API access are atomic Capabilities. Sandbox state is disposable runtime state. |
| SubAgent, delegation, parallel research, background task | One-off delegation is an ephemeral SubAgent Agentic Loop. Repeated delegation is itself a Workflow. The parent depends only on structured results, status, cost, and transcript reference when the node contract requires them. |
| ACP / Codex / Claude Code / Gemini CLI harness | An external Agent harness is carried by a SubAgent runtime Capability provider. Codex is one implementation in this runtime family. |
| Cron, scheduled jobs, one-shot reminders, heartbeat | Time-based Catch attributes on Nodes. Exact timing, intervals, aggregation, SLAs, and deliverable requirements belong to Workflow configuration. |
| Task Flow / background task ledger | A Segment produces recorded outcomes when its node contract requires them. SubAgent runs, sandbox runs, and external harness runs surface as node/Segment evidence. |
| Trajectory datasets, tool stats, learning signals | BullX extracts evaluations, preferences, policy improvements, Skill improvements, and future training signals from real Segments, Agentic Loops, tool calls, approvals, recorded outcomes, and KPI signals. |

The core tradeoff: the session, cron, heartbeat, SubAgent, and Skill file
structures that Hermes and OpenClaw expose for personal-agent usability can
keep a similar surface experience in BullX, but committed product truth
belongs to the owning durable store — usually PostgreSQL-backed Workflow
definitions, Principals, Budgets, Work, Brain, and audit records. Transient
Segment, Signal, and runtime state does not become durable truth just
because it appears inside a Workflow.

## Core concepts

BullX keeps its high-level concepts small and stable. Each concept must
explain product behavior rather than pre-commit BullX to a specific table or
supervision tree.

| Concept | Meaning |
| --- | --- |
| Installation | One BullX deployment and its single operating domain. BullX may serve an enterprise, a team, or an OPC operator, but does not default to SaaS multi-tenancy as the product boundary. |
| Principal | An internal subject that can be authorized, audited, and held responsible. Humans, AI Agents, services, and system actors are all Principals. |
| Connected Realm | An external identity and event space connected to BullX, such as a Feishu tenant, Slack workspace, or GitHub org. It is not a BullX tenant. |
| Workflow | A reactive process definition: an acyclic graph of Nodes describing how the system responds to domain events. A Workflow is structurally acyclic, but each execution activates only the Segment-relevant subgraph, not an end-to-end engine-held object. |
| Node | The only first-class structural element of a Workflow. A Node carries Catch, Throw, Executor, and the standard five categories (Contract, Execution binding, Governance, Effect, Lifecycle). |
| Catch | A Node attribute. When true, the Node is a valid entry point for an incoming Signal. Catch declares correlation criteria that select which Signals start a Segment at this Node. |
| Throw | A Node attribute. When true, the Node produces external side effects. Throw declares a destination, which may be a specific external target or the originating Catch context of the current Segment (commonly called Reply). |
| Executor | A Node attribute. Identifies what runs the Node: deterministic logic, an Agent, a Capability, a SubAgent runtime, a human task, or an external integration. |
| Segment | One stateless execution wave inside a Workflow. It starts from a matched Catch, activates Nodes along outgoing edges, and ends when all active branches have reached Sink positions, failed, or otherwise resolved according to the Segment contract. |
| Sink position | A branch terminator: either a Node with no outgoing edges, or a Catch-bearing Node reached through an incoming edge. The same Catch-bearing Node is not a Sink for the Segment that starts from it. |
| Correlation | The mechanism that selects, for an incoming Signal, which Catch attribute on which Workflow Node should start a Segment. Correlation may be definition-static (any Signal of this kind) or domain-keyed (matching a domain object reference). |
| Structural process identity | The business-process identity across Segments, determined by designated typed causal or correlation references among domain objects. It corresponds to what BPMN engines call a Process Instance, but BullX does not assign an engine-owned instance ID. |
| Agent | A digital work subject with AI work capability. When an Agent runs inside a Workflow, it is one kind of Node Executor, but it carries its own identity, memory, responsibilities, permissions, and KPIs. |
| Agentic Loop | One reasoning and tool-use loop of an Agent. It can run as a Node inside a Workflow or as the execution body of a one-off SubAgent. |
| Capability | A governed atomic ability that a Node may call: model, tool, browser, sandbox, messaging channel, or external API. External Agent harnesses are exposed through SubAgent runtime Capability providers. |
| Skill | A procedural knowledge asset that an Agent can read and use. A Skill can teach an Agent how to call a Capability, but it does not grant execution power. |
| SubAgent | A child Agentic Loop execution derived by an Agent or Workflow to isolate context, do bounded parallel work, or call an external Agent harness runtime. Long-running child work is modeled asynchronously through domain objects and keyed Catch continuation. |
| Human-in-the-loop | A participation pattern in which a human joins a Workflow as a Principal. Usually appears as a human task, approval, or policy-gate Node (a Catch-bearing Node that waits for human input). |
| Work | A durable work responsibility that persists across Segments. A Segment may create, advance, pause, resume, or complete Work. |
| Budget | A governance constraint over tokens, model cost, runtime, tool calls, external spend, or quota. A Budget can produce a hard stop, degradation, queueing, or over-budget approval. |
| Brain | BullX's long-term memory and reasoning world model. Brain durable truth remains in PostgreSQL. Brain forms evolvable memory from Workflows, Agent interactions, external events, and recorded outcomes. |

Two important boundaries:

Signal is the event input. A Signal is an incoming event; "what makes a
Workflow respond to it" is the Catch attribute on a Node. Time triggers,
webhooks, IM messages, human UI actions, and routing results are all Signals;
they enter the system as input to Catch-bearing Nodes.

Node is the structural unit. Sink position is a derived property of edge
topology and Catch placement, not a stored Node attribute.

Agent does not mean every executable subject. A deterministic transform,
approval Node, notification Node, CRM write Node, or blackhole branch is not
an Agent. Only a digital work subject with AI reasoning, memory, and a
responsibility boundary is an Agent.

## Workflow definition

A Workflow is a reactive process definition. Its graph is structurally
acyclic. Each execution activates only the Segment-relevant subgraph, not an
end-to-end engine-held object.

A Workflow describes:

- which Nodes may serve as entry points for which Signals (via Catch attributes
  and correlation criteria),
- which Nodes execute under which dependencies inside a Segment,
- which Nodes support streaming input or output,
- which Nodes terminate a Segment (Sink positions),
- which Nodes produce external side effects (Throw),
- which Nodes participate human Principals (human task, approval, policy gate),
- how Segment results are recorded as durable domain object writes.

BullX Workflows satisfy these constraints:

- A Workflow graph is acyclic. Loops inside an Agentic Loop, SubAgent
  runtime, or external runtime do not add cycles to the Workflow graph.
- A Workflow does not "complete" as a whole. Only Segments succeed or fail.
- The same Workflow definition can be executed by many uncoordinated Segments
  driven by different Signals at different times. The engine maintains no
  Segment-to-Segment linkage; cross-Segment continuity is the responsibility
  of domain objects.
- Streaming is an I/O delivery mode at the Node boundary. It is not a global
  Workflow execution mode.
- Reliability comes from recovery points, retries, idempotent node contracts,
  compensation, and operator recovery. BullX does not promise that every Node
  executes only once in every failure scenario.

Workflow edges express logical dependency and value passing within a Segment.
Streaming describes whether a value can be delivered incrementally before it
is fully materialized. In the current BullX context, streaming mainly means
LLM progressive response or token streaming for UI display, interactive reply,
log display, or a small number of downstream Nodes that support streaming
input. If a streaming payload reaches a Node that does not support streaming
input, BullX materializes or buffers it into complete input. If a Node
supports streaming output but the next Node does not support streaming input,
the next Node receives only the materialized final output.

## Node

A Node is the only first-class structural element of a Workflow. Every Node,
regardless of how it appears on a canvas or in documentation, carries the
same set of attributes. Differences that appear as separate canvas stencils
are expressed as values of Catch, Throw, and Executor.

**Catch (bool + correlation).** When `catch=true`, the Node is a valid entry
point for an incoming Signal that matches its correlation criteria. A Node
with `catch=true` and no incoming edges serves as a Workflow entry; a Node
with `catch=true` and incoming edges acts as an intermediate event catch
(commonly called a "Wait Node"). Correlation determines, for any given
Signal, whether this specific Catch should start a Segment. Correlation may
be definition-static ("any inbound IM message on this channel") or
domain-keyed ("the Lark approval webhook whose ticket_id matches an existing
domain reference").

**Throw (bool + destination).** When `throw=true`, the Node produces an
external side effect on completion. Destination identifies where the effect
goes: a specific external target such as CRM, Slack, webhook URL, ticketing
system, or the originating Catch context of the current Segment (commonly
called "Reply"). Internal audit records are committed product facts, not
Throw destinations, unless a design explicitly sends events to an external
audit system. Reply destinations are only available when the originating
Catch declared reply capability.

**Executor.** What runs the Node. Possible Executors include deterministic
logic, an Agent, a Capability (model, tool, sandbox, messaging, external
API), a SubAgent runtime, a human task, or an external integration.

In addition to these three core attributes, every Node expresses the five
high-level categories of execution information:

1. **Contract** — inputs, outputs, result states, and error semantics.
2. **Execution binding** — which Executor and configuration runs it.
3. **Governance** — which Principal permission it requires, which Budget it
   consumes, whether it triggers a policy gate or approval.
4. **Effect** — whether it has external side effects and how it handles
   retry, idempotency, deduplication, compensation, and audit.
5. **Lifecycle** — whether it supports streaming, pause/resume within the
   Segment, timeout, sink position, human handoff, and recovery.

A Sink position terminates the current branch. It is either a Node with no
outgoing edges, or a Catch-bearing Node reached through an incoming edge. The
same Catch-bearing Node is not a Sink for the Segment that starts from it; its
outgoing edges belong to that Segment. Sink position is not a Node attribute;
it is a property derived from Catch and graph topology. Blackhole is not a
special concept — it is simply a Node with no outgoing edges, no Throw, and
no continuation.

## Common Node patterns

The unified Node model gives users many degrees of freedom. For canvas
editing, documentation, and verbal communication, BullX recognizes a small
set of common Node patterns as conventional stencils. These are presentation
conveniences, not architectural categories.

- **Catch Node** — `catch=true`, often with no incoming edges. Entry point
  for a Workflow.
- **Wait Node** — `catch=true` with incoming edges. Intermediate event
  catch. When reached from upstream, it arms the wait by writing the
  required domain object and terminates the current branch. When a later
  Signal matches its Catch, a new Segment starts from the Catch boundary and
  continues downstream. The resume Segment must not repeat the arming side
  effect unless the Node contract explicitly allows it.
- **Throw Node** — `throw=true` with a specific external destination.
  External side effect node such as "send IM message," "write CRM note,"
  "create Lark ticket."
- **Reply Node** — `throw=true` with destination equal to the originating
  Catch context. Available only when the originating Catch declared reply
  capability.
- **Task Node** — neither Catch nor Throw. Pure internal computation, such
  as an Agent reasoning node, a deterministic transform, or a SubAgent
  invocation that does not produce external side effects.
- **Gateway Node** — multiple outgoing edges with branching conditions
  (exclusive, parallel, or inclusive). Borrowed from BPMN.
- **Human Task / Approval / Policy-Gate Node** — `catch=true` with incoming
  edges. A specialization of Wait Node that records a pending human action
  to the domain layer and waits for a correlated Signal carrying the
  human's response.

When a design doc or canvas refers to one of these patterns, it is using a
common shape of the unified Node concept, not introducing a new structural
element.

## Segment lifecycle and correlation

A Segment is one stateless execution wave inside a Workflow. Its lifecycle has
four phases:

**Match.** A Signal arrives. The runtime evaluates Catch attributes across
candidate Workflows to find every Node whose Catch matches the Signal. A
match may be definition-static (Signal kind alone is sufficient) or
domain-keyed (Signal carries domain reference that must match a stored
domain object the Catch is waiting on).

**Start.** For each match, the engine starts one Segment. The Segment
receives the Signal as initial input and begins executing from the matched
Catch Node.

**Execute.** The Segment activates Nodes along outgoing edges until all active
branches have reached Sink positions, failed, or otherwise resolved according
to the Segment contract. Within a Segment, intermediate execution state
(variables, node outputs, streaming buffers) lives in whatever substrate the
runtime contract selected — typically process memory, possibly with Redis or
unlogged PostgreSQL backing for recovery within the Segment. This state does
not need to survive the Segment.

**Record.** Before the Segment terminates, any Throw Nodes commit external
side effects, any domain object writes (Work updates, message records,
approval records, ticket creations) are committed to PostgreSQL, and any
recovery points required by the node contracts are written. After
termination, all Segment state is discarded.

The engine does not know whether a future Segment will continue any business
process this Segment was part of. If a Wait Node was reached from upstream,
the current Segment arms the wait by writing the required domain object and
terminates that branch. A future Signal matching that Wait Node's Catch starts
a new Segment from the Catch boundary and continues downstream. The resume
Segment must not repeat the arming side effect unless the Node contract
explicitly allows it. The engine does not retain a suspended Segment waiting
for that Signal.

No transient Node output crosses a Catch boundary. Any data needed after a
Wait or intermediate Catch must be committed as a domain object, artifact,
message record, approval record, or other product fact before the earlier
Segment terminates.

Correlation is the bridge between Signals and Workflow definitions. Every
Catch attribute declares either:

- **Open correlation:** any Signal of a declared kind matches (typical for
  Catch Nodes at Workflow entries — "any inbound IM message on this
  channel," "any GitHub issue webhook for this repo").
- **Keyed correlation:** the Signal must carry domain references that
  match a domain object stored by a previous Segment (typical for Wait
  Nodes — "a Lark approval response whose ticket_id matches a ticket this
  Workflow previously created").

A domain object that arms a keyed Catch must carry enough Workflow, Catch, and
compatible version identity to make later correlation and continuation
unambiguous after Workflow definition changes.

Keyed correlation is how BullX expresses what BPMN engines do with
suspended-instance lookup, without keeping a suspended instance. The
domain object created by the prior Segment is itself the correlation
record.

## Agent

An Agent is a digital work subject with AI work capability, long-term
memory, responsibility boundaries, permission boundaries, outbound identity,
and KPIs. When an Agent runs inside a Workflow, it appears as one kind of
Node Executor, but it is not an alias for ordinary Nodes or for a single
LLM loop.

An Agent should answer:

- What long-term goal or KPI does it serve?
- What Work can it create or advance?
- Which models, providers, integrations, or downstream Nodes can it call?
- Which Skills can it read?
- Which Capabilities and SubAgent runtimes can it use?
- Which Agent Principal does it execute as, and does this execution have
  triggering, authorizing, approving, or acting-on-behalf-of relationships?
- How do token, cost, runtime, and tool-call Budgets constrain it?
- Which Segment inputs can it see?
- Can its output be delivered as a stream?
- How does its result enter Brain and KPI evaluation?

Non-AI Nodes should not be called Agents to give them a sense of agency.
If a non-AI Node needs an independent audit identity, model it with a
Service Principal or System Principal instead of as a non-AI Agent.

An Agent usually has its own Agent Principal. One Agent Node execution
should also record the triggering Principal, authorizing or approving
Principal, and acting-on-behalf-of relationships. Agent identity and
delegated authorization must not collapse into one indistinguishable
subject.

## Skills and the virtual file system

BullX supports Skills, but Skill durable truth lives in PostgreSQL. Each
Skill has ownership, visibility, versioning, compatibility, review/policy
metadata, and content assets. Specific schemas, the VFS mutation protocol,
review state machines, and Skill Hub implementation belong to the Skill
design doc. This document constrains only the boundary.

To preserve the usage habits already formed by Hermes and OpenClaw, BullX
projects database-backed Skills into a virtual file system. Any execution
subject with Skill read permission — an Agent, a derived SubAgent internal
execution body, code running in a sandbox, import/export tooling — can see
a structure like:

```text
skills/
  customer-risk/
    SKILL.md
    references/
    templates/
    scripts/
```

This file tree is a projection, not a durable source. Writes to the
virtual file system translate into database mutations, version records,
permission checks, and audit events. Reads filter visible Skills by
Agent, Workflow, Principal, Connected Realm, platform compatibility, and
policy.

A Skill can contain scripts, templates, or example code as passive
assets. Executing those assets must go through a governed Capability or
Node. A Skill itself provides knowledge and materials. It does not grant
execution power, and it does not directly produce external side effects.
Shell, browser, API, message-sending, and external mutation execution
still belong to governed Capabilities or Nodes. This boundary keeps the
low-friction `SKILL.md` experience without hiding execution power inside
prompt files.

## Capability and SubAgent runtime

A Capability is an atomic ability that a Node may call: model, tool,
browser, sandbox, messaging channel, external API. Approval is not a
Capability; it is Node semantics (a Catch-bearing Wait Node specialized
for human approval). This keeps Capability as the atomic boundary for
"what can be done" while Node owns "when to do it, who does it, whether
to wait for approval, how to record the result."

A SubAgent runtime is a Capability provider that carries child Agentic
Loop runs. For bounded synchronous work under the Segment runtime contract, a
SubAgent Node declares task, policy, budget, timeout, result schema, and
handoff. It calls the SubAgent runtime Capability, creates a child Agentic
Loop run, and returns structured result, status, cost, and transcript
reference to the parent Segment. This boundary avoids flattening a full Agent
runtime into an ordinary tool and avoids promoting Codex, Claude Code, Gemini
CLI, or ACP harnesses into new top-level objects.

Sandbox-like Capabilities can run code, shell, browsers, tests, data
analysis, or external harnesses, but sandbox processes, temporary files,
and browser tabs are disposable state. Only explicitly recorded
artifacts, logs, outputs, patches, tool results, costs, and recovery
points can affect later Segment execution.

A SubAgent is a child Agentic Loop with isolated context. A parent Agent or
Workflow can delegate a bounded task to a SubAgent and specify model, Skills,
tool policy, sandbox policy, budget, timeout, fan-out limit, result schema,
and handoff channel. For synchronous bounded runs, the parent Segment should
not poll the child's private context; it should wait for the child to produce
a status change, structured result, failure reason, or timeout record.

Long-running child Agent or external harness work is modeled asynchronously:
the Segment records a child-run domain object and terminates at a keyed Catch;
a later child-completion Signal starts the continuation Segment. Synchronous
SubAgent execution inside one Segment is reserved for bounded work under the
Segment runtime contract.

The durability of a delegation pattern depends on product semantics. The
SubAgent itself is always an Agentic Loop with isolated context:

- One-off temporary parallel research, code inspection, experiments, or
  material organization: ephemeral SubAgent Agentic Loop. Transcript,
  tool calls, budget, and final result may still be recorded, but no
  reusable Workflow definition is created.
- Repeated delegation (daily market monitoring, weekly PR audits, hourly
  customer-risk scans, fixed multi-Agent research): model it as a
  Workflow. Schedule, input, Skills, budget, approval, delivery, and
  retry belong to the Workflow definition.

Codex is one implementation of the SubAgent runtime. BullX does not need
to make Codex a new top-level object. Codex is a child Agent called by a
SubAgent Node, constrained by sandbox and tool policy, managed by
budget, and recorded by the Segment.

## Time-driven Workflows

Cron jobs, scheduled tasks, one-shot reminders, and heartbeats from
Hermes and OpenClaw all land as Catch attributes on Nodes whose
correlation declares a time schedule. They are not parallel top-level
concepts. The Workflow configuration on the Catch decides exact timing,
approximate interval, aggregation, SLA, delivery target, no-op behavior
when nothing changed, and what domain object writes the Segment must
produce.

A background task ledger is not an orchestration system. SubAgent runs,
external Agent harness executions, sandbox executions, and isolated executions
may have records, but when the behavior needs multi-step dependencies,
retries, approvals, delivery, or long-term reuse, the real
orchestration object should be a Workflow.

A Workflow can contain SubAgent Nodes. The Agentic Loop inside a
SubAgent Node may continue to derive child SubAgents. Those derivations
happen inside the Node and do not add new Nodes to the parent Workflow
graph. Fan-out, nesting depth, concurrency, timeout, tool surface, and
budget are governance inputs. The default design should limit recursive
delegation so an Agent cannot use child Agents to bypass its own
permission, budget, or approval boundaries.

## Principal and identity

Principal is the internal identity root. Humans, AI Agents, services,
and system actors can all be Principals because all of them may be
authorized, audited, have permissions revoked, or carry responsibility.

Connected Realms provide external identity and event spaces, but do not
own BullX identity. Feishu, Slack, Discord, GitHub, Google, CRM, and
similar systems provide login assertions, external actors, event
provenance, or outbound credentials. BullX AuthN/AuthZ maps those
external proofs to internal Principals.

Principles:

- An external account is not a BullX user.
- An Adapter does not own identity; it only provides identity or event
  evidence.
- A Web session belongs to an internal Human Principal.
- An AI Agent can have its own Agent Principal.
- A non-AI Node that needs independent permission should use a Service
  or System Principal.
- Audit records should explain which Principal triggered, approved,
  executed, or acted on behalf of another subject.

The Principal represented by an Agent is first the Agent's own Agent
Principal. If one execution acts on behalf of a Human, service, team,
or external account, the execution records the triggering Principal,
authorizing or approving Principal, and acting-on-behalf-of relationship
as separate audit facts instead of merging them into one subject field.

## Human-in-the-loop

BullX models human-in-the-loop as a Workflow participation pattern, not
as engine-level long suspension. A human participates as a Principal
through a Node whose Catch waits for a Signal carrying human input —
approval, supplemental input, correction, takeover, escalation, or
final confirmation.

In the Workflow graph, this appears as a Wait Node specialized for
human participation (Human Task, Approval, Policy Gate). In the engine,
this is implemented as: the current Segment terminates at this Node
after writing a domain object that records the pending human action
(an approval request, an assigned task, a pending review). When the
human responds, the response arrives as a new Signal carrying a
reference to that domain object; correlation matches it back to the
Wait Node; a new Segment starts from the Catch boundary and continues
downstream. The resume Segment must not recreate the pending human action
unless the Node contract explicitly allows it.

The graph reads continuously across the human pause. The engine does
not. Cross-pause continuity is carried entirely by the domain object
(the pending approval, task, or review record), not by any suspended
Segment held in memory or in an engine table.

Human-in-the-loop does not only serve high-risk approval. It also
supports low-risk cases that need human judgment: adding missing
materials, choosing among candidates, confirming customer tone,
correcting an Agent's misjudgment, choosing among multiple follow-up
paths. Node configuration and policy gates decide the difference, not
ad hoc runtime convention.

## Governed external actions

External actions should be expressed by Throw Nodes, not hidden in
Agent prompts, provider SDKs, or free tool calls. A Throw Node needs
clear inputs, outputs, permissions, cost, risk, and audit boundaries.

High-risk external actions should not be executed directly by AI Agent
Nodes. Customer-facing, financial, legal, data deletion, contract,
payment, and permission-changing actions should pass through an
explicit approval or policy-gate Wait Node before the Throw Node
executes. This representation is easier to inspect, recover, and audit
than hiding safety logic in a prompt, adapter, or provider SDK.

Budget is also part of governance. BullX should support token, model
cost, runtime, external API spend, and tool-call limits by
Installation, Principal, Agent, Workflow, Node, Capability, and
SubAgent. When a budget is exceeded, the system explicitly chooses a
hard stop, degraded model, queueing, human approval request, or
supplemental Work. It must not rely only on prompt text asking an
Agent to "save tokens."

## Work and Structural Process Identity

Workflow definitions describe how the system reacts. Work expresses
durable responsibility. Structural process identity is the identity of a
business process across Segments.

Work persists across many Segments. A Segment may create, advance,
pause, resume, or complete Work. Work is a domain object in PostgreSQL
with its own lifecycle and observability.

Structural process identity is not a stored entity. It corresponds to what
BPMN engines call a Process Instance, but BullX forms it from designated
typed causal or correlation references among domain objects involved in a
business process, not by arbitrary foreign keys or incidental object links.
Issue #123 references ticket T456 references approval A789 references PR
P012 — this chain *is* the business process identity. Two Segments operating
on the same chain are operating on the same process; two Segments on disjoint
chains are on different processes. BullX does not maintain a separate engine
ID for instances and does not need to: the chain is observable, queryable,
and sufficient.

Long-term goals remain important but do not need a separate term in this
document. The key boundary: one Segment must not be mistaken for the
whole work responsibility. The value of an Agent is that it advances
Work across many Segments and improves later behavior from recorded
outcomes.

## Brain and memory

Brain is BullX's long-term memory and reasoning world model. It is not
only a log, and not a simple vector store. Brain is a logical-layer
concept; its physical durable truth lives in PostgreSQL. Brain extracts
evolvable objects, relationships, perspectives, and experiences from
Agent conversations, Segment inputs, external events, Node outputs, and
recorded outcomes.

Brain does not replace Workflow. Workflow owns execution. Brain lets
Agents act with better context and experience in later Segments.

Segment and Agentic Loop transcripts form recorded execution facts.
BullX can extract evaluations, preferences, policy improvements, Skill
improvements, and future training signals from recorded product facts
and execution evidence constrained by permissions, privacy, and
redaction. The trajectory / learning design doc owns specific data
formats, export process, training uses, and privacy policy.

```text
Segment execution
  -> Node inputs / outputs / recorded outcomes
  -> Brain ingestion and consolidation
  -> Better future Agent behavior in later Segments
```

## Typical scenarios

### Listening in a group chat without speaking

An IM Catch Node matches an inbound customer-group message and starts a
Segment. A risk-detection Node determines the message concerns a customer
budget freeze. `CustomerSuccessAgent`, running as an Agent-executed Node,
analyzes context and creates or updates customer-risk Work. A direct-
message Throw Node privately notifies the responsible owner. The group
does not need a reply, so the Workflow contains no Reply Node and no
Catch declared reply capability for this trigger.

### One Catch starts multiple branches

One external event arriving at one Catch Node fans out into multiple
branches inside the same Segment. The customer-risk branch executes
`CustomerSuccessAgent`, the financial-risk branch executes
`FinanceAgent`, and the unrelated branch reaches a no-edge Node and
ends. Branching and termination live in the graph; no "distribution
center" exists outside the Workflow.

### Streamable AI experience

An Agent Node declares `streaming_output=true`; a downstream Node
declares `streaming_input=true`. The Agent Node's logical output remains
the complete reply text or structured result; streaming only delivers
tokens or chunks incrementally before final materialization. If the
originating Catch declared reply capability, the Segment can route
streaming output to a Reply Node. If a downstream Node does not support
streaming input, BullX materializes the complete output before delivery.

### High-risk action through a gate

An Agent Node suggests sending a quote explanation to a customer but
cannot write the outbound message directly. The Workflow first enters a
policy-gate or human-approval Wait Node. The Segment ends here, having
recorded a pending approval domain object. When the approval response
arrives as a Signal, a new Segment starts from the Wait Node's Catch boundary
by correlation and continues downstream without recreating the pending
approval unless the Node contract explicitly allows it. If approved, the
outbound Throw Node executes. If rejected, the Segment records the result and
may notify the owner or create supplemental Work.

### Multi-turn IM conversation

A user has a three-turn conversation with an Agent over Slack. In
BullX this is three independent Segments sharing one Workflow
definition. Each inbound message matches the IM Catch Node and starts
a Segment that reads conversation history from the messages domain
table, runs the Agent, writes a new message record, and uses a Reply
Node back to the user. The Agent's "continuity" across turns is
entirely the messages table — there is no engine-held conversation
state. If the Agent decides mid-turn that it needs a human approval
to use a tool, it sends the request as part of its reply and the
Segment ends; when the user replies with approval, that is the next
Segment, which reads the message history (including the prior
request) and proceeds with the tool call.

### Cross-day approval Workflow

A Workflow listens for GitHub issue webhooks and, for issues
classified as in-scope, creates a Lark ticket and waits for human
approval before invoking a code-oriented external Agent harness to
fix the issue. The Workflow contains one entry Catch Node (GitHub
webhook), classification and ticket-creation Nodes, a Wait Node
(approval) keyed by ticket ID, a SubAgent Node (external Agent
harness), and a PR-creation Throw Node. In execution this becomes two
Segments: the first runs from the GitHub Catch through ticket
creation and ends at the Wait Node, recording the ticket as a domain
object with enough Workflow, Catch, and compatible version identity for
later continuation. Days later when the Lark approval webhook arrives,
keyed correlation matches it to the Wait Node by ticket ID, a second
Segment starts there, runs the SubAgent and the PR creation, and ends.
The two Segments share compatible Workflow definition identity but the
engine does not link them; the link is the ticket reference in the
domain layer.

### Skills drive reusable ability

An operations Agent handling customer renewal risk reads the
`customer-risk` Skill through the virtual file system. The Agent uses
the Skill to generate analysis and recommendations. If the work needs
to write CRM, send a message, or run code, the Segment continues into
Throw or SubAgent Nodes that call the corresponding governed
Capabilities under permissions, budget, and approval.

### Exact scheduling

A user asks for a customer-risk daily report at 9 a.m. BullX creates a
Workflow whose entry Catch Node has a time-schedule correlation set to
9 a.m. daily. Each morning that Catch starts a Segment that reads
Brain, CRM, yesterday's IM Signals, and unfinished Work, calls an Agent
to generate a summary, and delivers it through a messaging Throw Node.
Recorded outcomes belong to the Segment, not to an independent cron
log.

### Periodic awareness

A user asks an Agent to check for urgent items every 30 minutes. BullX
creates a Workflow with an interval-time Catch. Each Segment checks
inbox, calendar, child-task status, and high-priority Work. If nothing
changed, the Segment ends at a no-edge Node. If something changed, the
Segment creates Work or notifies the owner via Throw Nodes. When the
behavior needs exact timing, long analysis, or repeated deliverables,
the same Workflow can be reconfigured with an exact-schedule Catch and
SLA.

### Parallel research and one-off SubAgents

A main Agent needs to research three competitors at the same time. It
derives three ephemeral SubAgents, each with separate context, Skills,
sandbox, budget, and timeout. Because this is bounded work under the
Segment runtime contract, the current Segment waits for three structured
results and merges them. If "weekly competitor research" becomes stable,
that SubAgent orchestration becomes a Workflow.

### External Agent harness as child Agent

"Fix the failing tests in this repo." BullX calls a code-oriented
external Agent harness through a SubAgent Node with a controlled
workspace, tool policy, budget, and timeout. The child Agent modifies
code and runs tests, but external publishing, merging, deployment, or
high-risk credential access still requires a policy gate or human
approval Wait Node in the Workflow. The Segment records patch, test
output, cost, and final status. If the harness work is long-running, the
Segment records a child-run domain object and terminates at a keyed Catch;
the harness completion Signal starts the continuation Segment.

## Non-goals

This document does not define:

- Specific database schemas.
- Specific queues, workers, supervisors, or runtime modules.
- A specific adapter list.
- A specific Workflow DSL or UI canvas format.
- A specific approval policy language.
- Specific Skill table structures, Skill VFS protocol, or Skill Hub
  implementation.
- A specific sandbox backend, external Agent harness adapter, SubAgent
  queue, or thread-binding implementation.
- A specific token billing model, budget approval UI, or quota
  settlement system.
- Specific trajectory / learning data formats, export processes,
  training uses, or privacy policies.
- A specific Brain storage model.
- A SaaS multi-tenant isolation model.
- A specific correlation index, Signal dispatch implementation, or
  Catch registration mechanism.

Later design docs expand the reactive-process vocabulary from this
document instead of introducing parallel top-level subjects for the same
responsibilities.

## Design invariants

**Process model.**

- BullX is a reactive process definition system. A Workflow describes
  how the system responds to domain events; it is not "an automation
  the user launches and waits for."
- A Segment is one stateless execution wave inside a Workflow. It starts
  from a matched Catch, activates Nodes along outgoing edges, and ends
  when all active branches have reached Sink positions, failed, or
  otherwise resolved according to the Segment contract.
- A Workflow does not complete or fail as a whole; only Segments do.
- Structural process identity is derived from designated typed causal or
  correlation references among domain objects. The engine does not assign
  or maintain instance IDs.
- The engine is a stateless Segment executor. Cross-Segment continuity
  is the responsibility of the domain layer, not the engine.

**Graph structure.**

- A Workflow graph is acyclic. Loops inside an Agentic Loop,
  SubAgent runtime, or external runtime do not add cycles to the
  Workflow graph.
- Node is the only first-class structural element. Catch, Throw, and
  Executor are Node attributes. Edge is the only relation.
- Sink position is a derived property, not a Node attribute. It terminates
  the current branch and is either a Node with no outgoing edges, or a
  Catch-bearing Node reached through an incoming edge. The same
  Catch-bearing Node is not a Sink for the Segment that starts from it.
- Signal is the event input; Catch is the Node attribute that admits a
  matching Signal into a Segment.
- Reply is a Throw Node whose destination is the originating Catch context.

**Correlation and continuity.**

- Correlation is a first-class concept. Every Catch attribute declares
  open or keyed correlation criteria.
- Keyed correlation matches incoming Signals against domain object
  references stored by prior Segments. The domain object is the
  correlation record.
- BullX does not keep suspended-Segment state. A Wait Node reached from
  upstream arms the wait by writing the required domain object and
  terminates the current branch; a later Signal starts a new Segment from
  that Catch boundary by correlation.
- A resume Segment must not repeat the Wait Node arming side effect unless
  the Node contract explicitly allows it.
- No transient Node output crosses a Catch boundary. Any data needed after
  a Wait or intermediate Catch must be committed as a domain object,
  artifact, message record, approval record, or other product fact before
  the earlier Segment terminates.
- A domain object that arms a keyed Catch must carry enough Workflow,
  Catch, and compatible version identity to make later correlation and
  continuation unambiguous after Workflow definition changes.

**Persistence and recovery.**

- PostgreSQL is the source of truth for committed durable product
  facts.
- A recoverable Workflow does not imply a durable log of every Signal,
  stream chunk, internal loop, routing step, or intermediate runtime
  event.
- Process-local Segment state must be reconstructible from the
  external stores selected by its runtime contract, or explicitly
  disposable.
- Signal and runtime layers may use PubSub, Redis, unlogged
  PostgreSQL tables, ETS projections, or other non-durable substrates
  when loss before acceptance or commit is within the contract.
- Reliability uses recovery points, retries, idempotency,
  deduplication, compensation, and operator recovery. BullX does not
  promise that every Node executes only once in every failure
  scenario.

**Streaming and I/O.**

- Streaming input/output is a delivery mode at the Node boundary. It
  is not a global mode, an independent topology, or general
  stream-processing semantics.

**Subjects.**

- Non-AI execution logic is a Node, not an Agent.
- Only a digital work subject with AI reasoning, memory, and a
  responsibility boundary is an Agent.
- External Agent harnesses are carried by SubAgent runtime Capability
  providers. They are not new top-level architectural subjects.
- A one-off SubAgent is an ephemeral Agentic Loop. Repeated SubAgent
  orchestration is a Workflow.
- Long-running child Agent or external harness work is asynchronous:
  the Segment records a child-run domain object and terminates at a keyed
  Catch; a later child-completion Signal starts the continuation Segment.
- Synchronous SubAgent execution inside one Segment is reserved for bounded
  work under the Segment runtime contract.

**Skills.**

- Skill durable truth lives in PostgreSQL. The file tree is only a
  virtual file system projection.
- A Skill may contain passive assets but does not grant execution
  power. Executing scripts, templates, or example code must go through
  a governed Capability or Node.

**Sandboxes.**

- Sandbox Capability runtime state is ephemeral. Only explicitly
  recorded artifacts, outputs, logs, patches, recovery points, and
  results can affect later Segment execution.

**Human-in-the-loop.**

- Human-in-the-loop is a Workflow participation pattern, implemented
  as a Wait Node specialized for human input. It must be pausable
  (Segment-terminating), correlatable (so the response can match
  back), and auditable (the pending domain object is the record).

**Governance.**

- High-risk external side effects must pass through an explicit
  approval or policy-gate Wait Node before the producing Throw Node.
- Token Budgets, cost quotas, and over-budget approval belong to
  governance and must not exist only in prompt text.

**Brain and learning.**

- Brain durable truth lives in PostgreSQL.
- Trajectories and learning signals can only be based on recorded
  product facts and execution evidence constrained by permissions,
  privacy, and redaction.

**Audit.**

- Important product behavior must be auditable, explainable, and
  recoverable. This invariant is product-level; it does not require
  persisting every internal data-processing step.

## How later designs use this document

Later design docs treat this document as a vocabulary and direction
constraint, not as an implementation manual.

When a design describes an external entry point, it asks: what is the
Catch attribute on which Node, and what is its correlation? When a
design describes execution logic, it asks: what are the Catch, Throw,
and Executor of the Node; which Capabilities or SubAgent runtimes does
it call; does it support streaming; and is it a Sink position? When a
design describes an AI subject, it asks: what are this Agent's
long-term goals, Work, Agent Principal, memory, KPIs, Skills,
Capabilities, Budget, and callable Node boundaries? When a design
describes a multi-step business process, it asks: which designated typed
causal or correlation references among domain objects carry structural
process identity across Segments?

An implementation can temporarily cover only a small slice, but it
must not introduce permanent concepts that contradict these high-level
constraints. In particular, the engine must not hold stateful workflow
execution objects that resume across external waits; Signal remains event
input; Reply remains a Throw destination; and Catch, Throw, and Executor
remain Node attributes rather than distinct Node types.

## One sentence

BullX is an AgentOS for long-running digital work: it expresses
business reactions as reactive Workflow definitions over BPMN-shaped
acyclic graphs of Nodes whose Catch, Throw, and Executor attributes describe
how each step participates; the engine executes those Workflows as
stateless bounded Segments; structural process identity is carried by
typed domain object reference chains in PostgreSQL;
Principals, Budgets, and Node-level governance control permission and
cost; SubAgent runtimes, sandbox Capabilities, and human-in-the-loop
Wait Nodes participate as ordinary Nodes; Skills, Brain, and recorded
outcomes accumulate organizational memory; and real Segment execution
facts drive continuous improvement.
