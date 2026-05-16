# BullX High-Level Architecture

BullX is an AgentOS for AI colleagues. It accepts Events from chat, webhooks,
timers, human operations, and child tasks; routes each Event to its Target
through an Event Routing Rule; and invokes the Target through a TargetSession.

The EventBus owns the global Event Routing Rule table. When an Event arrives,
the EventBus performs a priority-ordered short-circuit match against that
table, taking the first matching rule. Each Event Routing Rule declares a
match condition, a Target, and how the scope and time window of the
TargetSession are determined.

A Target is an Event consumer and handler. The typical Targets are AIAgent
and Workflow. An AIAgent is an AI colleague: it can process Events directly,
hold conversations, use tools, advance Work, request human help, and use the
Brain. A Workflow is an explicit process suited for branching, approval,
parallelism, and deterministic steps.

A TargetSession is the execution window formed by one Event Routing Rule
within a particular scope and time window. It receives the Events matched by
that rule within the window and dispatches them to the Target. A
TargetSession may be carried by an Oban Job, but the Event itself is not
written into the Oban Job arguments — Events arrive through a side channel.

The EventBus and TargetSession layer is responsible for Event delivery and
execution-window management. It does not hold business facts. It may retain
runtime records for delivery, retry, or observability, but those records are
not business facts. Business facts are stored by business-layer objects:
conversations live in Conversation and Message, durable responsibility lives
in Work and Task, approvals live in ApprovalRequest, child tasks live in
ChildRun, long-term memory and representation live in Brain, and cost lives
in Budget. Once a TargetSession closes, any later approval, callback, or
child-task completion arrives as a new Event on the EventBus and enters a
new TargetSession.

One BullX Installation is one deployment and one operating domain. A
Connected Realm provides an external identity and event space. Principal,
Budget, Skill, Capability, and Brain decide whom a Target may act on behalf
of, how much it may spend, what knowledge it may read, what abilities it may
call, and how long-term memory forms from work outcomes.

This document fixes only the high-level execution model and vocabulary
boundary of BullX. Concrete table schemas, APIs, modules, and configuration
belong to their respective design documents.

## Minimal execution model

The minimal execution model of BullX is: an Event enters the EventBus, the
EventBus matches an Event Routing Rule, and a TargetSession invokes the
Target.

```text
Event arrives
  -> EventBus short-circuit matches the first Event Routing Rule by priority
  -> the matched Event Routing Rule creates or reuses a TargetSession
  -> the Event enters the TargetSession
  -> the TargetSession invokes the Target
  -> the Target processes the Event
```

The EventBus routes Events to matching TargetSessions. The Target and the
business layer decide how the business processing happens, what data is
written, and what outbound messages are sent.

By default, only the first matching Event Routing Rule accepts an Event. If
an Event must trigger multiple paths, the matched Target expresses that
explicitly.

## Core vocabulary

**Event** An Event is an external or internal signal received by BullX. IM
messages, webhooks, timer fires, approval clicks, ChildRun completion
events, and human UI actions are all Events.

**Installation** An Installation is one BullX deployment and its single
operating domain. It may serve an enterprise department, a team, or an OPC
operator; SaaS multi-tenancy is not a default product boundary.

**Connected Realm** A Connected Realm is an external identity and event
space connected to BullX, such as a Feishu tenant, a Slack workspace, a
GitHub organization, or a CRM space. A Connected Realm supplies external
accounts, Event sources, login assertions, and outbound credentials.
Internal BullX identity is expressed by Principal.

**EventBus** The EventBus is the Event entry point of BullX. It receives
Events, short-circuit matches Event Routing Rules by priority, and dispatches
Events into TargetSessions.

**Event Routing Rule** An Event Routing Rule is an entry in the global
routing table. It describes the Event match condition, the Target invoked on
match, and the scope and time window of the resulting TargetSession. Its
responsibility is limited to routing; business processing belongs to the
Target.

**Target** A Target is the consumer and handler invoked when an Event
Routing Rule matches. A Target may be an AIAgent, a Workflow, a
Blackhole / Ignore, an External Agent Harness, or another Target defined by
a subsequent design document.

**TargetSession** A TargetSession is the execution window formed by one
Event Routing Rule within a particular scope and time window. It receives
the Events matched by that rule within the window and dispatches them to the
Target.

**TargetSession side channel** The TargetSession side channel is the runtime
path by which an Event reaches a TargetSession. It is not an Oban Job
argument, and it is not a business-fact store. Its concrete implementation
belongs to the corresponding runtime design document.

**AIAgent** An AIAgent is an AI colleague. It can serve directly as a
Target, handling conversations, long-running work, judgment, collaboration,
memory, tool use, and human cooperation.

**Agentic Loop** An Agentic Loop is one round of reasoning and tool use
inside an AIAgent. It is internal to an AIAgent or SubAgent and is not
automatically expanded into Workflow Nodes.

**Workflow** A Workflow is an explicit-process Target. It consists of Nodes
and is suited for branching, approval, parallelism, deterministic steps,
external actions, and human intervention.

**Principal** A Principal expresses who triggers, who authorizes, who
approves, and who executes. Human users, AIAgents, services, and system
actors can all be Principals.

**Budget** A Budget limits token usage, model cost, tool calls, runtime,
external spend, or quota.

**Skill** A Skill is a procedural knowledge asset that an AIAgent can read.
A Skill can describe how to use a Capability but does not grant execution
power.

**Capability** A Capability is a governed ability that an AIAgent or
Workflow may call, such as a model, tool, browser, sandbox, messaging
channel, or external API. Permission, approval, recording, and execution
details belong to the Capability and Governance design documents.

**SubAgent** A SubAgent is a child Agentic Loop delegated by an AIAgent or
Workflow. It carries an isolated context, Skills, tool policy, sandbox
policy, Budget, timeout, and result format.

**Brain** Brain is the long-term memory and representation subsystem. It
distills traceable, evolvable, retrievable reasoning-style memory from
conversations and Event streams, and maintains a world model that grows step
by step.

**Cortex** A Cortex is a memory region in Brain organized by observation
perspective. A Cortex binds an observer to an observed subject and holds the
observer's memory of and reasoning about that subject.

**Engram** An Engram is a memory imprint in Brain. It holds reasoning-style
memory distilled from a conversation, an Event, a tool result, or a later
consolidation. It does not store a copy of the raw message.

**Dreamer** Dreamer is the background consolidation mechanism of Brain. It
merges duplicate Engrams, surfaces contradictions, lifts the abstraction
level, and helps Brain's world model grow from observation.

**Work / Task** Work is a durable responsibility that persists across
multiple TargetSessions. Task is a concrete work item. A TargetSession may
create or advance Work and Task; Work carries the long-term responsibility.

## Event Routing Rule

An Event Routing Rule is an entry in the global routing table. It defines
three things:

- which Events it matches,
- which Target receives the Event on match,
- how the scope and time window of the TargetSession are determined.

The responsibility of an Event Routing Rule ends at routing. When it
matches, it creates or reuses a TargetSession, writes the Event into the
TargetSession side channel, and lets the TargetSession invoke the Target.

Wildcard and default rules are legitimate. An Event not accepted by any more
specific rule may match a fallback Event Routing Rule and enter a default
Target or a Blackhole / Ignore Target.

## Target

A Target is the Event consumer and handler invoked when an Event Routing
Rule matches.

Typical Targets include:

- **AIAgent** — an agent consumer suited for conversation, long-running
  work, judgment, collaboration, memory, and tool use.
- **Workflow** — an explicit-process consumer suited for branching,
  approval, parallelism, deterministic steps, and external actions.
- **Blackhole / Ignore** — an explicit drop of the Event.
- **External Agent Harness** — a Codex-style external Agent runtime.

Different Event Routing Rules pointing to the same Target form different
TargetSessions by default. The same Target can be invoked by many
TargetSessions; whether a TargetSession is reused is determined by the
scope and time window defined on the matched Event Routing Rule.

## TargetSession

A TargetSession is the execution window formed by one Event Routing Rule
within a particular scope and time window. It receives the Events matched by
that rule within the window and dispatches them to the Target.

A TargetSession may be carried by an Oban Job. The Oban Job arguments hold
only meta information such as the TargetSession identity, the Event Routing
Rule identity, the Target identity, the scope, and `expires_at`. The Event
is not written into the Oban Job arguments; it arrives through the
TargetSession side channel.

Once a TargetSession is closed or expires, it does not accept new business
Events. Later approval clicks, callbacks, ChildRun completion events, later
IM replies, and Time Events return through the EventBus. If those Events
need to continue the same business work, the EventBus matches the
corresponding Event Routing Rule and creates or reuses a new TargetSession.

A TargetSession is an execution window. The business layer holds the
complete business history and business facts.

## Installation and Connected Realm

An Installation is the BullX operating domain. The EventBus, Principals,
Budgets, Brain, Work, and Conversations of one Installation share the same
business boundary.

A Connected Realm connects external identity and event spaces. A Feishu
tenant, a Slack workspace, a GitHub organization, a Google Workspace, and a
CRM space can all be Connected Realms. External accounts, login assertions,
outbound credentials, and Event sources originate in Connected Realms, but
they only supply evidence; internal BullX authorization and accountability
are carried by Principals.

An Adapter is responsible only for connecting to an external system. An
Adapter may supply identity hints, Event evidence, or delivery capacity,
but it does not own a BullX identity and does not decide which Principal
receives authorization.

## Principal and identity

Principal is the internal identity root of BullX. Human users, AIAgents,
services, and system actors can all be Principals, because each of them may
be authorized, audited, have permissions revoked, or carry responsibility.

Audit records should state which Principal triggered, authorized, approved,
or executed an action, or acted on behalf of another subject. External
accounts are not BullX users. A web session belongs to an internal Human
Principal. An AIAgent normally has its own Agent Principal.

When a Target execution acts on behalf of a human, a service, a team, or an
external account, the triggering Principal, the authorizing or approving
Principal, the executing Principal, and the on-behalf-of relationship are
recorded separately. Agent identity and delegated authorization must not
collapse into one ambiguous field.

## AIAgent and Workflow

AIAgent is the most important Target. An AIAgent can serve directly as a
Target and process Events. It can hold conversations, use tools, read
Skills, call external APIs, delegate SubAgents, create Work and Tasks,
request human help, and use Brain, all under permission and Budget
constraints.

An AIAgent should declare its long-term goals, KPIs, the Work it can
handle, the Skills it can read, the models, Model Providers, Integrations,
Capabilities, and SubAgent runtimes it can call. It should also declare its
outbound identity, its Agent Principal, its Budget constraints, and how its
results enter Brain and KPI evaluation.

An AIAgent may read context provided by Brain; its conversations, tool
results, Work processing, and external Events may become inputs that Brain
ingests for reasoning.

An AIAgent can hold long-running Work across many TargetSessions. One
SalesAgent may simultaneously handle several channels, several conversations
or threads, and several pieces of Work, but those are different
TargetSessions by default.

An AIAgent identity is not the same as an Event Routing Rule identity, nor
the same as any TargetSession. One AIAgent can be the target of multiple
Event Routing Rules and can be invoked by multiple TargetSessions.

An AIAgent may run many turns of reasoning and tool calls internally. Those
internal steps stay inside the AIAgent; they are not automatically modeled
as Workflow Nodes. A Workflow Target is used only when the user needs an
explicit process, branching, approval, parallelism, deterministic steps, or
a visualized process boundary.

A Workflow is a Target oriented at explicit-process scenarios that an
AIAgent does not satisfy. A Workflow consists of Nodes; a Node is a step in
the Workflow. A Node can be a tool call, conditional, approval, human task,
external action, message reply, or similar. Event routing is performed by
the EventBus and Event Routing Rules.

A Target execution carries the necessary Principal, Budget, and permission
context. When an AIAgent or Workflow calls a tool, sends a message, creates
Work, or performs an external action, that action is bound by this context.

Both AIAgent and Workflow may use governed models, tools, browsers,
sandboxes, messaging channels, external APIs, and External Agent Runtimes.
Permission, approval, recording, and execution details belong to the
Capability and Governance design documents.

## Skill

A Skill is a procedural knowledge asset. The durable business facts of
Skills live in PostgreSQL; the Skill VFS is a file-tree projection for
AIAgents, SubAgents, sandboxes, and import/export tooling.

A Skill can carry owner, visibility, version, compatibility, review
metadata, policy metadata, and content assets. When a Skill is read, the
view is filtered by AIAgent, Target, Principal, Connected Realm, platform
compatibility, and policy.

A Skill may include scripts, templates, or example code, but those assets
are passive material. Executing scripts, opening a browser, calling APIs,
sending messages, or mutating external systems must go through a governed
Capability or Target.

## SubAgent and External Agent Harness

A SubAgent is a child Agentic Loop. An AIAgent or Workflow may delegate a
bounded task to a SubAgent and specify model, Skills, tool policy, sandbox
policy, Budget, timeout, concurrency limit, result format, and handoff.

A short-lived SubAgent can return structured results, status, cost, and a
transcript reference within the current TargetSession. A long-running
SubAgent or External Agent Harness writes to a ChildRun; on completion,
failure, or timeout, it returns to the EventBus as a new Event and enters a
new TargetSession.

An External Agent Harness can serve as a Target, or be used by an AIAgent
through a SubAgent. Codex, Claude Code, Gemini CLI, and ACP are external
Agent runtimes of this kind. They are constrained by sandbox, tool policy,
and Budget; they do not become new identity roots.

Sandbox processes, temporary files, and browser tabs are runtime state.
Only explicitly recorded Artifacts, Logs, Patches, tool results, costs, and
status records affect later business processing.

## Budget and external actions

Budget limits tokens, model cost, runtime, tool calls, external API spend,
and quota. Budget may apply to an Installation, a Principal, an AIAgent, a
Target, a Workflow, a Capability, or a SubAgent.

When a Budget is exceeded, the system must explicitly choose to stop,
degrade the model, queue, request human approval, or create follow-up Work.
Budget constraints must appear in runtime and business records, not only in
prompts.

Customer-visible, financial, legal, deletion, permission-changing, or
otherwise high-risk external actions must produce auditable business
records, pass through policy or approval when required, and execute through
a governed Capability or Target. Internal tool calls of an AIAgent do not
need to be pre-expanded as Workflow Nodes, but high-risk actions must not
live only in prompts.

## Brain

Brain is responsible for the formation, evolution, and retrieval of
long-term memory. AIAgents and Workflows can read context provided by
Brain; the conversations, tool results, Work processing outputs, and
external Events they produce can become inputs to Brain.

The durable business facts of Brain live in PostgreSQL. Brain distills
objects, relationships, perspectives, and experiences from conversations,
TargetSession inputs, external Events, Target outputs, and business
results.

Brain memory is organized by Cortex. A Cortex expresses an observation
perspective — for example, a SalesAgent's memory of a particular customer,
a ResearchAgent's memory of a company or market event, or the system's
global memory of a subject. The same subject can appear in multiple
Cortexes and acquire different memory under different perspectives.

Engram is the memory unit inside a Cortex. An Engram may come from a
conversation message, an Event, a tool result, or a later Dreamer
consolidation. An Engram records distilled reasoning-style memory and does
not duplicate the raw input.

Dreamer performs background consolidation. It merges duplicate or close
Engrams, surfaces contradictions between memories, lifts higher-level
judgments from many low-level memories, and lets Brain's world model grow
from real work over time. Dreamer scheduling, cost control, concrete table
schemas, and retrieval strategy belong to the Brain design document.

Trajectory and learning data can come only from recorded business facts and
execution evidence, and are constrained by permission, privacy, and
redaction policy. Concrete data formats, export flows, training uses, and
privacy policy belong to the Trajectory / Learning design document.

## Persistence boundary

The EventBus and TargetSession layer is responsible for Event delivery and
execution-window management. It does not store business facts. Business
facts are stored by the business layer:

- Conversation / Message holds AIAgent conversations.
- Work / Task holds long-running responsibility and task state.
- ApprovalRequest holds approval state.
- ChildRun holds long-running child-task state.
- Artifact holds produced outputs.
- Brain holds long-term memory, representation, and reasoning-style memory.
- Budget holds cost and quota.

PostgreSQL is the source of truth for committed business facts. The
EventBus, TargetSession, and other runtime layers may retain runtime
records for delivery, buffering, retry, observability, and coordination.
Those runtime records are not business facts and are not cross-TargetSession
business identities. Their concrete storage shape belongs to the runtime
design document.

Business objects express continuity across many TargetSessions; a closed
TargetSession does not carry that continuity. After a TargetSession closes,
later approvals, callbacks, child-task completions, or user replies arrive
as new Events on the EventBus and enter new TargetSessions.

Typed reference chains among business objects express the structured
identity of one piece of business work. For example, an Issue references a
Ticket, a Ticket references an ApprovalRequest, and an ApprovalRequest
references a PullRequest. The chain is queryable and auditable, and it is
sufficient to show that those Events and TargetSessions belong to one piece
of business work. The EventBus and TargetSession do not assign an additional
business-process instance ID.

Important product behavior must be auditable, explainable, and recoverable.
The audit boundary covers facts that affect Work, ApprovalRequest, policy
outcome, Principal delegation, high-risk external action, Artifact, and
cost. It does not require persisting every internal reasoning step, every
streaming chunk, or every runtime forwarding step.

## Subsequent Events and cross-window continuity

A subsequent Event may continue the same piece of business work, but it
does not return to a TargetSession that has closed or expired. Human
approval, supplemental information, human takeover, correction, task
completion, external callback, and ChildRun completion all arrive as new
Events on the EventBus and are routed to a new TargetSession by the
corresponding Event Routing Rule.

Human-in-the-loop is not only for high-risk approval. Adding materials,
choosing among candidates, confirming customer tone, correcting an
AIAgent's judgment, choosing among follow-up paths, and completing offline
tasks can all produce new Events.

A cross-day approval flow looks like this:

```text
Initial Event matches an Event Routing Rule
  -> TargetSession invokes Target
  -> Target writes ApprovalRequest
  -> TargetSession closes or expires
  -> days later, an approval click becomes a new Event
  -> EventBus matches the corresponding Event Routing Rule
  -> a new TargetSession invokes the Target
```

Some Targets produce streaming output, such as an AIAgent reply. Streaming
delivery is an implementation detail of the Target or the message channel.
It does not change the core model of Event Routing Rule, TargetSession, and
Target.

## Time Event

Timers, crons, reminders, and heartbeats produce Time Events. A Time Event
enters the EventBus like any other Event.

How Time Events are produced belongs to the Scheduler design. How Time
Events are handled after they arrive belongs to Event Routing Rules and
Targets.

## Typical scenarios

### Listening in a group chat without replying

A group message enters the EventBus as an Event. The EventBus routes it to
a RiskMonitoringAgent or a Workflow Target. The Target may create Work and
privately remind the responsible owner, without replying in the group.

### One Event drives process logic

A budget-freeze message matches a Workflow Target. Inside the Workflow,
branches handle customer success, financial risk, and the ignore path.
Those branches belong to the Workflow Target.

### Multi-turn IM conversation

The same Event Routing Rule forms the same TargetSession within the same
conversation or thread and time window. Different channels, even with the
same SalesAgent Target, form different TargetSessions by default.

### Cross-day approval

After a Target writes an ApprovalRequest, its TargetSession may close.
Days later, an approval click is a new Event. The EventBus matches the
corresponding Event Routing Rule and creates a new TargetSession; the new
TargetSession invokes the Target.

### Scheduled task

The scheduler produces a Time Event. The EventBus routes the Time Event to
a ScheduledReportAgent or a Workflow Target. The Target generates a report,
creates Work, or sends a message.

### High-risk external action

An AIAgent suggests sending a quote explanation to a customer. The Target
first writes an ApprovalRequest or a high-risk-action record. When the
approval Event returns to the EventBus, a new TargetSession invokes the
Target to complete delivery or record the rejection.

### Skill supports reusable capability

An OperationsAgent reads the `customer-risk` Skill and generates a renewal
risk analysis. When CRM writes, message sends, or code runs are needed, the
Target executes through governed Capabilities or an External Agent Harness,
under Principal, Budget, and approval constraints.

### External Agent Harness / Codex

A Codex-style External Agent Harness can serve as a Target or be delegated
as a SubAgent by an AIAgent. Long-running execution writes to a ChildRun;
on completion, failure, or timeout, it returns to the EventBus as a new
Event and enters a new TargetSession.

## Non-goals

This document does not define:

- Concrete table schemas.
- Concrete runtime modules, supervision trees, Worker implementations, or
  Oban queue configuration.
- A concrete Event Routing Rule DSL, Target registry, Workflow DSL, or UI
  canvas format.
- Concrete Workflow Node contracts.
- Concrete execution details of tools, models, browsers, sandboxes,
  messaging channels, APIs, or External Agent Runtimes.
- A concrete approval policy language, Budget settlement scheme, or
  approval UI.
- Concrete Principal / AuthN / AuthZ table schemas or policy language.
- A concrete Connected Realm Adapter list, login protocol, or outbound
  credential format.
- Concrete Skill tables, Skill VFS protocol, Skill Hub, Brain table
  schemas, retrieval strategy, or learning data formats.
- Concrete sandbox backends, External Agent Harness adapters, Trajectory /
  Learning data formats, export flows, training uses, or privacy policy.
- A SaaS multi-tenant isolation model.

## Design invariants

- Event is the input signal.
- The EventBus short-circuit matches Event Routing Rules by priority.
- An Event Routing Rule is a match condition plus a Target plus a
  TargetSession scope.
- By default, only the first matching Event Routing Rule accepts the Event.
- Target is the Event consumer and handler.
- The typical Targets are AIAgent and Workflow.
- An AIAgent may serve directly as a Target without first being modeled as
  a Workflow.
- Workflow is the explicit-process Target; BullX may also process Events
  directly through an AIAgent.
- A TargetSession is the execution window formed by one Event Routing Rule
  within a particular scope and time window.
- An Event is not written into the Oban Job arguments.
- An Event arrives through the TargetSession side channel.
- A closed or expired TargetSession does not accept new business Events.
- Business objects express cross-window continuity; a closed TargetSession
  does not carry that continuity.
- Business facts are persisted by business-layer objects.
- An Installation is the single operating domain of BullX; a Connected
  Realm is an external identity and event space.
- Principal is the internal identity root; external accounts and Adapters
  do not own BullX identity.
- Principal, Budget, and Brain support responsibility, cost, long-term
  memory, and representation.
- Skill is a knowledge asset and the Skill VFS is its projection; a Skill
  does not grant execution power.
- Capability is the governed ability that an AIAgent or Workflow may call.
- A SubAgent is a child Agentic Loop; the result of a long-running SubAgent
  or External Agent Harness returns to the EventBus through a ChildRun and a
  new Event.
- High-risk external actions must produce auditable business records and
  pass through policy or approval when required.
- Sandbox runtime state is transient; only explicitly recorded Artifacts,
  Logs, Patches, tool results, costs, and status records affect later
  business processing.
- PostgreSQL holds committed business facts; runtime records carry only
  delivery, buffering, retry, observability, and coordination duties.
- Typed business-object reference chains express the structured identity of
  one piece of business work; the EventBus and TargetSession do not assign
  an additional business-process instance ID.
- Brain is supported by Cortex, Engram, and Dreamer: Cortex organizes
  observation perspectives, Engram holds reasoning-style memory, and
  Dreamer performs background consolidation.
- Brain is responsible for the formation, evolution, and retrieval of
  long-term memory; it is not responsible for Event routing or Target
  execution.
- Trajectory and learning data can come only from recorded business facts
  and execution evidence, under permission, privacy, and redaction
  constraints.
- Principal carries authorization and accountability; a Target or Workflow
  Node is not itself a Principal.
