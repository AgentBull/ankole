# Signal routing

## Summary

BullX implements signal routing as a Runtime-owned routing system. Gateway stays
a transport boundary: it normalizes external events into `BullX.Gateway.Signal`,
calls the configured Router, and persists returned `DeliveryIntent` values
through the Mailbox. Runtime projects each Signal into a `RoutingContext`,
evaluates fixed-column route rules, and emits `RouteIntent` deliveries to zero
or more destinations.

The top-level model is:

```text
Signal -> Route -> Destination
```

A destination is either an Agent Principal or a system sink. Agent destinations
cover AI agents, DAG workflow agents, decision-tree agents, rule-based agents,
observer agents, and other Agent runtime shapes. The Router does not inspect how
an Agent works internally. The first system sink is an explicit blackhole drop.

This replaces the legacy Dynamic Runtime Targets plan with
`Signal -> Route -> Destination`, without Jido dependencies, `runtime_targets`,
target kinds, route-owned LLM configuration, or a Router-level Admission model.
Admission remains a useful Agent attention concept: an Agent runtime may admit,
ignore, defer, or escalate a routed Signal after Agent ingress receives it. The
Router itself answers the simpler question: where should this Signal go?

## Prerequisites

This design relies on these documents:

- [SignalsGateway](SignalsGateway.md), for `BullX.Gateway.Signal`,
  `DeliveryIntent`, `Mailbox`, `Router`, `ConsumerDelivery`, configured sources,
  external actors, delivery outcomes, and reply channels.
- [Principal](Principal.md), for Human and Agent Principals, external identity
  bindings, and Agent profiles.
- [AuthZ](AuthZ.md), for Principal-centered authorization.
- [LLMProvider](LLMProvider.md), for caller-owned LLM specs and provider
  catalog resolution.
- [Configuration](Configuration.md), for runtime configuration and cache
  startup ordering.
- [Plugins](Plugins.md), for adapter and provider extension boundaries.

The legacy
`rfcs/plans/0014_Dynamic_Runtime_Targets_and_Routing.md` is a mechanics
reference only. It contributes persisted rules, fixed match columns,
deterministic ordering, reconstructible runtime cache, writer-triggered refresh,
and focused route tests. It does not define the current ontology.

## Scope

This design covers the first current-branch routing slice:

- a Runtime implementation of the `BullX.Gateway.Router` behaviour;
- a Runtime `ConsumerDelivery` dispatcher for Gateway Mailbox workers;
- `RoutingContext` projection for Gateway inbound and delivery outcome Signals;
- adapter-normalized routing facts for selected provider payload details;
- PostgreSQL-backed route rules;
- deterministic routing from one Signal to zero or more destinations;
- explicit terminal blackhole drops;
- durable `signal_route_decisions` rows created from Gateway Mailbox jobs;
- cache, writer, telemetry, failure behavior, tests, and implementation
  handoff.

This slice stops at the Agent ingress boundary. It does not implement the full
Agent reasoning loop, Agent attention admission, Work creation, Capability
execution, Intent generation, Governance approval, external Effect execution,
Brain memory, or KPI evaluation. Agent runtimes consume delivered
`signal_route_decisions` after their own designs define their runtime and
persistence contracts.

## Baseline stories

The design supports these routing stories without special-case topology:

| Story | Route expression |
| --- | --- |
| Feishu quant bot duplex messages go to `Quant`. | Match the Feishu configured source and message event; deliver to the `Quant` Agent with `input_mode = interactive`. |
| Feishu, Telegram, and Discord support bots all go to `Support`. | Use one route rule per configured source; each delivers to the same `Support` Agent. |
| GitHub webhook events go to a DAG workflow. | Match the GitHub source and event name; deliver to the workflow Agent Principal. |
| GitHub payload details select a specialized Agent. | The adapter projects safe routing facts from the payload; route rules match those facts. |
| One Feishu bot routes group `a` to Agent A and group `b` to Agent B. | Match `scope_id = group_a` or `scope_id = group_b` under the same configured source. |
| A timer emits a Signal that goes to a decision-tree Agent. | Treat the timer as a Signal producer; match the timer Signal type or scope and deliver to the Agent. |
| A news websocket push fans out to two Agents. | Two matching route rules deliver the same Signal to two Agent Principals. |

These stories are routing stories. They ask BullX to send a class of Signals to
a handler. Admission is too narrow for the top-level model because it assumes
the destination is an Agent attention space and frames the decision as
visibility. Route is the product-level noun users and operators can explain.

## Goals

- Route normalized Gateway Signals to destinations through Route rules, not to
  generic Runtime targets.
- Allow one Signal to deliver to several Agent Principals.
- Treat AI agents, DAG workflow agents, decision-tree agents, rule-based agents,
  scheduler-driven agents, and observer agents as Agent destinations.
- Support explicit blackhole routes without modelling blackhole as an Agent.
- Keep Gateway unaware of Agent selection, Route rule syntax, Work, Intents, and
  Governance.
- Keep route rules as fixed-column data with PostgreSQL constraints, not
  executable code, arbitrary module names, raw payload predicates, or predicate
  ASTs.
- Let adapters expose selected provider payload details as stable routing facts.
- Store durable route decisions in PostgreSQL while keeping the runtime cache
  reconstructible.
- Route to durable Agent Principals whose profiles own later attention, runtime,
  and LLM configuration, without storing models, prompts, provider secrets, or
  target configs in route rules.
- Support Gateway inbound Signals and Gateway delivery outcome Signals through a
  shared `RoutingContext` projection.

## Non-goals

- Do not add Jido, `Jido.Signal.Router`, `AgentServer`, `Action`, `Directive`,
  or compatibility shims for old Jido concepts.
- Do not add `runtime_targets`, `runtime_inbound_routes`, target kinds, or
  `agentic_chat_loop` route targets.
- Do not make routing choose exactly one Agent. Fan-out to several Agents is a
  core requirement.
- Do not store LLM model selections, prompts, tool catalogs, skills, or provider
  credentials in route rules.
- Do not let route rules parse arbitrary raw provider payloads.
- Do not add a generic JSON predicate language, Cedar expression language,
  executable callback, regex engine, or LLM classifier to the first router.
- Do not add a durable inbound Signal table under Gateway. Runtime stores route
  decision records, not a Gateway-owned Signal log.
- Do not introduce a tenant model. `{adapter, channel_id}` remains a configured
  source, not a tenant id.
- Do not add an all-Signal catch-all rule. A default assistant route must be a
  default inbound route for `com.agentbull.x.inbound.received`.
- Do not let Gateway adapters call Agent code or deliver external messages
  directly.
- Do not implement arbitrary internal-service destinations in the first slice.
  The first sink is an explicit blackhole drop.
- Do not implement record-only route decisions or a record sink. A Signal archive
  or audit stream needs its own storage design.
- Do not support actor Principal matching in the first slice. Rules may match
  the channel-local actor id and bot flag, but not `actor_principal_id` or actor
  Principal presence.
- Do not implement scheduled task orchestration, durable chat sessions, Work
  orchestration, Governance, Effects, or outbound delivery policy in this
  design.
- Do not add a Phoenix management UI. The first slice exposes writer APIs and
  tests.

## Existing system

`BullX.Gateway` already has the boundary this design needs. `publish/2`
constructs a strict CloudEvents `BullX.Gateway.Signal`, calls the configured
`BullX.Gateway.Router`, normalizes returned `DeliveryIntent` values, and
enqueues them through the Oban-backed Mailbox. `SignalDeliveryWorker` restores
each `DeliveryIntent` and calls the configured `BullX.Gateway.ConsumerDelivery`.

`BullX.Gateway.Signal` uses strict CloudEvents 1.0 JSON Event Format. BullX
extension attributes are top-level CloudEvents properties such as
`bullxoccurkey`, `bullxadapter`, and `bullxchannel`. Signal routing must not
assume or accept a nested `extensions` map. Implementation code may use helper
functions over the `BullX.Gateway.Signal` struct, but the routing design always
refers to the serialized top-level CloudEvents extension attributes.

Gateway carrier types are:

```text
com.agentbull.x.inbound.received
com.agentbull.x.delivery.succeeded
com.agentbull.x.delivery.failed
```

Inbound Gateway Signals use the `content + event` data contract. Delivery
outcome Signals use `data["delivery"]` and `data["outcome"]` and do not contain
`data["event"]`, `data["scope_id"]`, or `data["thread_id"]` at the same paths as
inbound Signals. Runtime therefore matches over `RoutingContext`, not raw
`Signal.data`.

`BullX.Principals` defines `principals`, `human_users`, `agents`, and
`principal_external_identities`. Signal routing references Agent Principals as
destinations. Gateway actors remain channel-local in the first routing slice;
actor Principal resolution belongs to a later Agent ingress, Governance, or
actor-aware routing design.

`BullX.AuthZ` authorizes active Principals but does not infer identity from
Gateway actors. The first signal-routing slice does not perform policy
authorization beyond active Agent destination eligibility. Receive-permission
checks, richer conditions, and Effect authorization belong to later Governance
or Agent ingress designs.

`BullXAIAgent.LLM` resolves caller-owned LLM specs such as
`"openai_proxy:gpt-4.1-mini"`. Signal routing never resolves an LLM provider
while matching rules. Agent runtime code later reads Agent profile data and
calls the LLM catalog when it actually needs reasoning.

## Domain model

### Signal

A Signal is the normalized statement that something happened. In this design,
the Gateway Signal is the routing input and one source for decision snapshots.
The Gateway Signal is not a task, not a Work item, and not a database row owned
by Gateway.

Timer programs, websocket feeds, chat adapters, webhook adapters, and future
internal producers can all create Signals. The first implementation uses the
Gateway `Router` contract because Gateway already owns normalized Signal
publication and durable Mailbox enqueue.

### RoutingContext

`RoutingContext` is the normalized routing projection extracted from a Gateway
Signal. It contains the facts that route rules may match: carrier type,
configured source, external scope, event names, channel-local actor facts,
selected adapter-normalized routing facts, outcome facts, and safe identifiers.
Matcher code consumes `RoutingContext`, not raw Signal maps.

### Routing fact

A routing fact is a safe, adapter-normalized key/value fact that exposes a
provider payload detail for routing. A route rule may match one routing fact by
exact key and exact value. If an adapter needs to route on labels, branch
classes, repositories, market categories, duplex capability, or provider
actions, the adapter projects those values into `Signal.data["routing_facts"]`.
`RoutingContext.routing_facts` is loaded only from that stable path.

The Router must not parse arbitrary provider payload paths such as
`data["pull_request"]["labels"]`. Adapters own provider-specific payload
knowledge. Route rules match stable routing facts.

### RouteRule

A `RouteRule` is an operator-managed rule that matches a `RoutingContext` and
produces one routing outcome. A rule may deliver to an Agent or explicitly drop
the Signal through a blackhole sink.

Rules are relational data because they reference Agent Principals, need
constraints, need deterministic ordering, and must be auditable.

### RouteIntent

A `RouteIntent` is a Gateway `DeliveryIntent` whose consumer type asks Runtime
to persist one route decision for one destination and one Signal publish. The
Router returns `DeliveryIntent` values, not database rows.

### RouteDecision

A `RouteDecision` is the durable decision produced when a `RouteIntent` is
consumed. It records that one Signal publish matched a route rule and produced a
concrete routing outcome:

- deliver the Signal to one Agent;
- drop the Signal through an explicit blackhole route.

RouteDecision answers these questions:

- Which route rule matched?
- Which destination did the route choose?
- Did the route deliver or drop?
- Which routing facts were used?
- For Agent delivery, which input mode should Agent ingress use?

RouteDecision is not authorization to perform external effects. It is an input
to Agent ingress, Agent attention, Work, Intent, and Governance.

### Destination

A Destination is the concrete place a Route sends a Signal. The first slice has
two destination families:

| Destination | Meaning |
| --- | --- |
| Agent destination | Deliver the Signal to an active Agent Principal. |
| Sink destination | Produce a system outcome without delivering to an Agent. |

Agent destinations use `agent_principal_id`. The first sink destination uses
`sink_kind = blackhole`.

### Agent destination

An Agent destination is an active Agent Principal with an `agents` extension
row. Routing rules reference `agents.principal_id`. A disabled Agent Principal
cannot receive new Agent deliveries even if a stale queued `RouteIntent` still
references it.

The Router does not branch on Agent implementation type. The same route model
delivers to AI loop Agents, DAG workflow Agents, decision-tree Agents,
rule-based Agents, scheduler-driven Agents, and observer Agents.

### Sink destination

A Sink destination is a non-Agent system outcome. The first slice supports:

| Sink | Action | Meaning |
| --- | --- | --- |
| `blackhole` | `drop_signal` | A matching terminal route explicitly drops the Signal and records why. |

Implicit no-match is different from blackhole. If no route rule matches, Router
returns `{:ok, []}` and creates no internal delivery. An explicit blackhole
route creates a durable drop decision for operator explanation and can override
broader delivery rules by priority.

### Route action and input mode

Route action states what the Router decided to do:

| Action | Meaning |
| --- | --- |
| `deliver_agent` | Deliver the Signal to one Agent destination. |
| `drop_signal` | Explicitly drop the Signal through the blackhole sink. |

Agent delivery may include an input mode:

| Mode | Meaning |
| --- | --- |
| `silent` | The Agent may process internally but must not propose a public reply to the originating surface from this route alone. |
| `interactive` | The Agent may propose a reply or follow-up Intent, subject to Governance. |

Input mode is a delivery hint from routing to Agent ingress. It is not an
Admission outcome. Agent attention may still ignore, defer, admit, or escalate
the routed Signal according to Agent-runtime policy.

## System shape

Signal routing sits between Gateway publish and destination consumption:

```text
Gateway Signal
-> Runtime Router
   -> RoutingContext projection
   -> RouteMatcher
   -> RouteIntent DeliveryIntent
-> Gateway Mailbox / SignalDeliveryWorker
-> BullX.Runtime.ConsumerDelivery
   -> BullX.Runtime.SignalRouting.RouteConsumer
   -> signal_route_decisions
   -> Agent runtime reads deliver_agent decisions after its own design exists
   -> sink stop for drop_signal
```

The Mailbox remains the Gateway acceptance boundary. Runtime creates
`signal_route_decisions` when Oban delivers the already resolved `RouteIntent`.
This keeps Gateway's durable contract unchanged while making RouteDecision the
business-level routing record.

## RoutingContext projection

`RoutingContext` uses top-level CloudEvents fields and top-level BullX extension
attributes. It must reject or fail to load a Signal shape that contains a nested
`extensions` map.

A valid Gateway Signal should always produce a base `RoutingContext`. Unknown or
unsupported carrier types project the base CloudEvents and BullX extension facts
and set carrier-specific fields to nil. They normally produce no matches
because every route rule requires `signal_type` and at least one additional
non-`signal_type` match, except for the deliberate broad inbound Agent route
shape allowed by the writer. Projection errors are reserved for Gateway contract
bugs and should be covered by focused tests, not treated as normal retryable
routing outages.

The shared projection contains these facts:

| Field | Source |
| --- | --- |
| `signal_id` | CloudEvents `id`. |
| `signal_type` | CloudEvents `type`. |
| `signal_time` | CloudEvents `time`; required because Gateway fills provider time or receive time. |
| `signal_occurrence_key` | Top-level `bullxoccurkey`. |
| `adapter` | Top-level `bullxadapter`. |
| `channel_id` | Top-level `bullxchannel`. |
| `scope_id` | Carrier-specific projection. |
| `thread_id` | Carrier-specific projection. |
| `event_type` | Carrier-specific projection. |
| `event_name` | Carrier-specific projection. |
| `actor_external_id` | Carrier-specific projection. |
| `actor_bot` | Carrier-specific projection. |
| `outcome_status` | Carrier-specific projection for delivery outcomes; not a fixed rule column in the first slice. |
| `routing_facts` | Adapter-normalized string or string-list facts safe for routing. |
| `routing_snapshot` | Redacted routing explanation safe for all route decisions, including embedded `routing_facts`. |
| `content_snapshot` | Optional content projection allowed only for Agent delivery decisions. |

Carrier projection starts with these rules:

| Signal type | Projection |
| --- | --- |
| `com.agentbull.x.inbound.received` | `scope_id = data["scope_id"]`; `thread_id = data["thread_id"]`; `event_type = data["event"]["type"]`; `event_name = data["event"]["name"]`; `actor_external_id = data["actor"]["id"]`; `actor_bot = data["actor"]["bot"]`. |
| `com.agentbull.x.delivery.succeeded` | `scope_id = data["delivery"]["scope_id"]`; `thread_id = data["delivery"]["thread_id"]`; `event_type = nil`; `event_name = nil`; actor fields are nil; `outcome_status = data["outcome"]["status"]`. |
| `com.agentbull.x.delivery.failed` | Same delivery projection as `delivery.succeeded`; `outcome_status = "failed"`. |

Adapters add routing facts to normalized inbound input under the top-level
`routing_facts` key. `BullX.Gateway.InboundInput.normalize/2` validates that
value and stores it inside the serialized Signal at `data["routing_facts"]`.
The Router does not read routing facts from top-level CloudEvents extension
attributes, arbitrary provider payload paths, `event.data`, `refs`, or
`metadata`. Delivery outcome Signals start with an empty routing-fact object
unless Gateway explicitly adds safe outcome routing facts in a later design.

Examples:

```text
gateway.reply_capable = "true"
github.action = "opened"
github.repo = "agentbull/bullx"
github.object_kind = "pull_request"
github.label = "security"
github.branch_class = "release"
news.publisher = "example-news"
timer.name = "daily-risk-report"
```

Routing facts must be a JSON object whose values are non-empty strings or arrays
of non-empty strings. Arrays must not be empty. Booleans, numbers, nulls,
nested objects, mixed arrays, secret values, raw webhook bodies, user-edited
display names used as identity proof, and large provider payload fragments must
not enter `routing_facts`.

Future internal Signal carrier types must add an explicit projection before
route rules can match them. They must not rely on incidental paths inside
`Signal.data`.

## Routing design

### Rule evaluation

`BullX.Runtime.SignalRouting.Router.resolve/1` performs these steps:

1. Project the Gateway Signal into `RoutingContext`.
2. Load the current normalized route rule snapshot from
   `BullX.Runtime.SignalRouting.Cache`.
3. Return `{:ok, []}` immediately when the snapshot is empty.
4. Evaluate fixed columns and routing facts to find matching rules.
5. Apply terminal drop ordering.
6. Group non-drop matching rules by destination.
7. Select one winning rule per destination with deterministic ordering.
8. Build one `RouteIntent` `DeliveryIntent` per winning rule.

The Router does not write database rows and does not resolve Gateway actors to
Principals in the first slice. Agent Principal reads are limited to destination
eligibility checks for `deliver_agent` rules.

### Fixed match columns

Rules match `RoutingContext`, not raw `Signal.data`. `NULL` match columns are
wildcards except for `signal_type`, which is required for every rule.

| Column | Match source |
| --- | --- |
| `signal_type` | `RoutingContext.signal_type`; required. |
| `adapter` | `RoutingContext.adapter`. |
| `channel_id` | `RoutingContext.channel_id`. |
| `scope_id` | `RoutingContext.scope_id`. |
| `thread_id` | `RoutingContext.thread_id`; `NULL` means wildcard. |
| `actor_external_id` | `RoutingContext.actor_external_id`. |
| `actor_bot` | `RoutingContext.actor_bot`. |
| `event_type` | `RoutingContext.event_type`. |
| `event_name` | Exact `RoutingContext.event_name`. |
| `routing_fact_key` | A key in `RoutingContext.routing_facts`. |
| `routing_fact_value` | Exact value for `routing_fact_key`; matches a string value or an item in a string array. |

`routing_fact_key` and `routing_fact_value` must be set together.
`routing_fact_value` is stored as text. The first slice supports one exact
routing fact match per rule. If a provider needs to route on a small composite
condition, the adapter should project a stable derived fact such as
`github.branch_class = "release"` or `github.triage_bucket = "security_pr"`. A
generic payload predicate language is not part of this design.

The first slice does not support actor Principal matching or
`actor_principal_presence`. A later actor-aware routing design may add presence
matching, but `unresolved` must mean that BullX attempted Principal lookup and
found no active bound Principal. It must not mean that the Router skipped lookup.
Rules that match either `resolved` or `unresolved` presence would therefore make
Principal storage a routing dependency for those candidate Signals.

The first slice does not add `neq`, `in`, regexes, nested `event.data` matching,
Cedar expressions, event-name prefix matching, score thresholds, LLM
classifiers, executable callbacks, actor Principal columns, actor presence
columns, or an `outcome_status` rule column. If a caller needs a small allowlist,
it creates several rows or adapter-projected facts. If a caller needs event-name
families, the adapter should project a stable routing fact. If a caller needs a
global exclusion, it creates a higher-priority `drop_signal` route.

### Destination grouping

Route grouping prevents duplicate deliveries to the same destination:

| Route action | Destination key |
| --- | --- |
| `deliver_agent` | `"agent:" <> agent_principal_id` |
| `drop_signal` | `"sink:blackhole"` |

When several non-drop rules match the same destination, Runtime chooses the
winner by deterministic ordering. Different Agent destinations may all win, so
one Signal can fan out to several Agents.

### Ordering

When several rules compete, Runtime ranks them by:

1. higher `priority`;
2. lexicographically smaller `key`.

Ordering is per destination after terminal drop handling. A high-priority route
to one Agent does not suppress another Agent's route. The first slice does not
use match-column scoring or weights. Operators must resolve overlapping rules by
setting explicit priorities.

### Terminal drop

`drop_signal` is a terminal route action only when the globally highest ranked
matching rule is a blackhole rule. Runtime ranks all matching rules by
`priority`, then `key`. If the highest ranked rule is `drop_signal`, Router emits
exactly one blackhole `RouteIntent` and no other intents. If any `deliver_agent`
rule outranks every matching drop rule, normal destination fan-out proceeds and
lower-ranked drop rules do not suppress it.

This gives operators a simple override rule: use a higher-priority blackhole
route to explain and enforce a global drop. The first slice does not implement a
per-Agent suppress action. If BullX later needs "do not deliver to Agent A but
still deliver to Agent B," that behavior should be designed explicitly rather
than reintroduced through Admission terminology.

### Default inbound route

The current design does not add the legacy code-owned `main` fallback. A fresh
Installation without route rules returns `{:ok, []}` from the Router and Gateway
accepts no internal deliveries for that Signal.

A default assistant route is a default inbound Agent route, not an all-Signal
catch-all. It is an ordinary writer-created route with this shape:

```text
signal_type = "com.agentbull.x.inbound.received"
route_action = "deliver_agent"
```

and the other match columns wildcarded. The writer permits this broad route only
for inbound Agent delivery. All route rules require `signal_type`; a rule with
every match column including `signal_type` null is invalid. A future all-Signal
catch-all would be a separate high-risk operator API because it could match
delivery outcome Signals and create loops.

## Delivery intent contract

The Router returns valid `BullX.Gateway.DeliveryIntent.t()` values. It may use
`BullX.Gateway.DeliveryIntent.from_signal/2` internally, but the Router contract
is the Gateway behaviour contract:

```elixir
resolve(BullX.Gateway.Signal.t()) ::
  {:ok, [BullX.Gateway.DeliveryIntent.t()]} | {:error, term()}
```

A `RouteIntent` uses these delivery fields:

| Field | Requirement |
| --- | --- |
| `route_id` | `"signal_route_rule:" <> rule.id`; rule UUID is the immutable routing identity. |
| `consumer_key` | `"signal_route_destination:" <> destination_key`. |
| `delivery_key` | Gateway canonical key derived from occurrence key, route id, consumer key, and delivery kind. |
| `consumer.type` | `"signal_route_intent"`. |
| `consumer.schema_version` | `1`. |
| `consumer.rule_id` | Matched rule UUID as a snapshot. |
| `consumer.rule_key` | Matched operator-facing rule key as a snapshot. |
| `consumer.route_action` | `deliver_agent` or `drop_signal`. |
| `consumer.destination_key` | Stable destination key for idempotency and explanation. |
| `consumer.agent_principal_id` | Target Agent Principal id for `deliver_agent`; nil for sink actions. |
| `consumer.sink_kind` | `blackhole` for `drop_signal`, nil for Agent delivery. |
| `consumer.input_mode` | Agent input mode for `deliver_agent`; nil for sink actions. |
| `consumer.reason` | Stable reason code. |

`route_id` uses the immutable rule UUID, not the mutable rule key. `rule_key`
stays in the consumer snapshot for operator explanations. If the rule is
deleted before the Mailbox job runs, the route consumer persists `rule_id =
NULL` and keeps the `rule_key` snapshot.

Gateway `delivery_key` remains the Mailbox idempotency boundary. The route
decision idempotency boundary is different: it is `{signal_id,
destination_key}`. This keeps route decisions publish-attempt scoped. Repeated
publication of the same external occurrence receives a new Signal id and can
create a new decision under current routing rules after the Mailbox dedupe
window. `delivery_key` and `signal_occurrence_key` are stored and indexed for
traceability, but they are not the unique route decision key.

## Runtime consumer dispatch

Gateway should be configured with the Runtime dispatcher:

```elixir
config :bullx, :gateway,
  router: BullX.Runtime.SignalRouting.Router,
  consumer_delivery: BullX.Runtime.ConsumerDelivery
```

`BullX.Runtime.ConsumerDelivery` implements `BullX.Gateway.ConsumerDelivery` and
dispatches by `intent.consumer["type"]`. In the first slice:

```text
signal_route_intent -> BullX.Runtime.SignalRouting.RouteConsumer
```

Unknown consumer types return `{:discard, {:unknown_consumer, type}}` unless a
separate Runtime design owns that type. Gateway does not learn SignalRouting,
Agent runtime, workflow, operator inbox, or other business consumer modules.

For `signal_route_intent`, `BullX.Runtime.SignalRouting.RouteConsumer`:

1. loads the embedded Gateway Signal snapshot from the `DeliveryIntent`;
2. rebuilds the `RoutingContext` projection for carrier facts and persistence;
3. checks that `deliver_agent` references an Agent Principal that still exists,
   is active, and has an `agents` row;
4. inserts or returns the existing `signal_route_decisions` row by
   `{signal_id, destination_key}`;
5. persists `rule_id = NULL` if the rule row no longer exists, while preserving
   `rule_key`;
6. stops when `route_action` is `drop_signal`;
7. returns `:ok` for persisted `deliver_agent` decisions.

For `drop_signal`, `RouteConsumer` must build only the routing snapshot and must
not construct `content_snapshot`. This prevents dropped Signals from becoming a
content archive through the sink path. Rebuilding `RoutingContext` is only for
carrier projection and persistence of routing facts.

The first routing implementation stops after durable decision persistence and
telemetry. A later Agent runtime design will define how Agent processes discover,
claim, or consume `deliver_agent` decisions without changing Gateway or route
matching.

## Actor identity

Signal routing does not resolve the Gateway actor to a Principal in the first
slice. Rules may match `actor_external_id` and `actor_bot` as channel-local
facts, but the Router does not call
`BullX.Principals.resolve_channel_actor/3`, does not create Principals, does not
bind external identities, and does not log in Humans.

A later actor-aware routing design may add `actor_principal_id` or
`actor_principal_presence`. If it does, `unresolved` must be a lookup result:
the Router must attempt Principal resolution and determine that no active bound
Principal exists. It must not treat skipped lookup, absent actor ids, or storage
unavailability as `unresolved`.

## Data and persistence

### Enum types

Add native PostgreSQL enums:

```sql
CREATE TYPE signal_route_action AS ENUM
  ('deliver_agent', 'drop_signal');

CREATE TYPE signal_agent_input_mode AS ENUM
  ('silent', 'interactive');

CREATE TYPE signal_sink_kind AS ENUM
  ('blackhole');
```

These sets are closed for the first implementation. Adding a new route action,
input mode, or sink kind requires a migration and matching Ecto enum update.

### `signal_route_rules`

Route rules are relational data because they reference Agent Principals, need
constraints, and will be queried and audited.

| Column | Type | Constraint |
| --- | --- | --- |
| `id` | `uuid` | Primary key, generated by `BullX.Ecto.UUIDv7`. |
| `key` | `text` | Required, unique, lowercase, matches `^[a-z][a-z0-9_-]{0,62}$`. |
| `name` | `text` | Required. |
| `description` | `text` | Nullable. |
| `enabled` | `boolean` | Required, default `true`. |
| `priority` | `integer` | Required, default `0`, `0 <= priority <= 100`. |
| `signal_type` | `text` | Required exact match. |
| `adapter` | `text` | Nullable exact match. |
| `channel_id` | `text` | Nullable exact match. |
| `scope_id` | `text` | Nullable exact match. |
| `thread_id` | `text` | Nullable exact match. |
| `actor_external_id` | `text` | Nullable exact match. |
| `actor_bot` | `boolean` | Nullable exact match. |
| `event_type` | `text` | Nullable exact match. |
| `event_name` | `text` | Nullable exact match. |
| `routing_fact_key` | `text` | Nullable exact key. |
| `routing_fact_value` | `text` | Nullable exact value. |
| `route_action` | `signal_route_action` | Required. |
| `agent_principal_id` | `uuid` | Required only for `deliver_agent`; FK to `agents(principal_id)`. |
| `sink_kind` | `signal_sink_kind` | `blackhole` for `drop_signal`, null for `deliver_agent`. |
| `input_mode` | `signal_agent_input_mode` | Required for `deliver_agent`, null for sink actions. |
| `reason` | `text` | Required stable reason code. |
| `metadata` | `jsonb` | Required object, default `{}`. |
| `inserted_at`, `updated_at` | `utc_datetime_usec` | Required. |

Database constraints:

- `signal_type IS NOT NULL`;
- `(routing_fact_key IS NULL) = (routing_fact_value IS NULL)`;
- `routing_fact_key IS NULL OR routing_fact_key ~ '^[a-z][a-z0-9_.:-]{0,127}$'`;
- `jsonb_typeof(metadata) = 'object'`;
- `reason ~ '^[a-z][a-z0-9_.:-]{0,127}$'`;
- one route target combination holds:
  `(route_action = 'deliver_agent' AND agent_principal_id IS NOT NULL AND
  sink_kind IS NULL AND input_mode IS NOT NULL) OR (route_action =
  'drop_signal' AND agent_principal_id IS NULL AND sink_kind = 'blackhole' AND
  input_mode IS NULL)`;
- at least one non-`signal_type` match column is non-null, unless the route is a
  broad inbound Agent route with `signal_type =
  'com.agentbull.x.inbound.received'`, `route_action = 'deliver_agent'`, and all
  other match columns null.

This exception prevents accidental broad rules while still allowing a deliberate
default assistant Agent route. The writer validates it as an ordinary route row,
not through a special-purpose API.

### `signal_route_decisions`

Route decisions are durable business records produced from Mailbox jobs. They
store routing explanation for all decisions and content only for Agent delivery
decisions. Routing facts are embedded inside `routing_snapshot`; the first slice
does not add a separate `routing_facts` column to `signal_route_decisions`.

| Column | Type | Constraint |
| --- | --- | --- |
| `id` | `uuid` | Primary key, generated by `BullX.Ecto.UUIDv7`. |
| `delivery_key` | `text` | Required Gateway delivery key. |
| `signal_occurrence_key` | `text` | Required top-level `bullxoccurkey`. |
| `signal_id` | `uuid` | Required CloudEvents id. |
| `signal_type` | `text` | Required. |
| `signal_time` | `utc_datetime_usec` | Required. |
| `adapter` | `text` | Nullable Gateway adapter id. |
| `channel_id` | `text` | Nullable configured source id. |
| `scope_id` | `text` | Nullable projected scope. |
| `thread_id` | `text` | Nullable projected thread. |
| `event_type` | `text` | Nullable projected event type. |
| `event_name` | `text` | Nullable projected event name. |
| `actor_bot` | `boolean` | Nullable projected actor bot flag. |
| `external_actor` | `jsonb` | Required redacted object, default `{}`. |
| `destination_key` | `text` | Required stable destination key. |
| `route_action` | `signal_route_action` | Required. |
| `agent_principal_id` | `uuid` | Nullable FK to `agents(principal_id)`. |
| `sink_kind` | `signal_sink_kind` | Nullable sink kind. |
| `input_mode` | `signal_agent_input_mode` | Required for Agent delivery, null for sink actions. |
| `rule_id` | `uuid` | Nullable FK to `signal_route_rules(id)`. |
| `rule_key` | `text` | Required snapshot of the matched rule key. |
| `reason` | `text` | Required stable reason code. |
| `routing_snapshot` | `jsonb` | Required redacted routing explanation, including embedded `routing_facts`. |
| `content_snapshot` | `jsonb` | Nullable Agent delivery content projection. |
| `decision_metadata` | `jsonb` | Required object, default `{}`. |
| `inserted_at`, `updated_at` | `utc_datetime_usec` | Required. |

Indexes and constraints:

- unique index on `{signal_id, destination_key}`;
- index on `{signal_occurrence_key, destination_key}`;
- index on `delivery_key`;
- index on `{agent_principal_id, inserted_at}` where
  `agent_principal_id IS NOT NULL`;
- index on `{sink_kind, inserted_at}` where `sink_kind IS NOT NULL`;
- `jsonb_typeof(external_actor) = 'object'`;
- `jsonb_typeof(routing_snapshot) = 'object'`;
- `content_snapshot IS NULL OR jsonb_typeof(content_snapshot) = 'object'`;
- `jsonb_typeof(decision_metadata) = 'object'`;
- `destination_key ~ '^[a-z][a-z0-9_:-]{0,190}$'`;
- `reason ~ '^[a-z][a-z0-9_.:-]{0,127}$'`;
- one route target combination holds:
  `(route_action = 'deliver_agent' AND agent_principal_id IS NOT NULL AND
  sink_kind IS NULL AND input_mode IS NOT NULL) OR (route_action =
  'drop_signal' AND agent_principal_id IS NULL AND sink_kind = 'blackhole' AND
  input_mode IS NULL)`;
- `route_action = 'deliver_agent' OR content_snapshot IS NULL`.

`rule_id` uses `ON DELETE SET NULL` so historical decisions survive rule
deletion. The route consumer must also handle the queued-intent case where the
rule was deleted before the decision row was inserted: it writes `rule_id =
NULL` and preserves `rule_key`.

### Snapshot policy

`routing_snapshot` is allowed for all route decisions. It contains the safe
routing explanation: Signal id, occurrence key, type, adapter, channel, scope,
thread, event type, event name, embedded `routing_facts`, actor bot flag,
redacted actor identity, rule key, reason, action, and destination key.

`content_snapshot` is allowed only for `deliver_agent` decisions. It may include
the normalized content projection and reply metadata that Agent ingress needs.
`drop_signal` decisions must not construct or store message text, attachment
fallback text, `reply_channel`, or other content. A future full content archive
or replay store must be designed as a separate storage surface, not smuggled
into route decisions.

## Runtime and operations

### Modules

Create the routing implementation under Runtime:

```text
lib/bullx/runtime/consumer_delivery.ex
lib/bullx/runtime/signal_routing.ex
lib/bullx/runtime/signal_routing/cache.ex
lib/bullx/runtime/signal_routing/matcher.ex
lib/bullx/runtime/signal_routing/route_consumer.ex
lib/bullx/runtime/signal_routing/route_decision.ex
lib/bullx/runtime/signal_routing/route_intent.ex
lib/bullx/runtime/signal_routing/routing_context.ex
lib/bullx/runtime/signal_routing/rule.ex
lib/bullx/runtime/signal_routing/router.ex
lib/bullx/runtime/signal_routing/writer.ex
```

Responsibilities:

- `BullX.Runtime.ConsumerDelivery` is the Gateway worker-facing Runtime
  dispatcher.
- `SignalRouting` is the public facade for reads and dispatch helpers.
- `Rule` and `RouteDecision` are Ecto schemas.
- `Writer` is the only supported write path for rules. It validates Agent
  eligibility, fixed match columns, routing facts, the broad inbound Agent route
  exception, route action combinations, and enum combinations.
- `Cache` starts under `BullX.Runtime.Supervisor`, loads enabled rules whose
  Agent Principals are active when required, stores the current snapshot in
  reconstructible state, and refreshes after writer commits.
- `RoutingContext` owns carrier projection, adapter-normalized routing facts,
  and snapshot construction.
- `Router` implements `BullX.Gateway.Router`.
- `Matcher` owns fixed-column rule matching, routing fact matching, terminal
  drop handling, and ordering.
- `RouteIntent` builds Gateway `DeliveryIntent` values.
- `RouteConsumer` persists `signal_route_decisions`.

### Startup

`BullX.Runtime.Supervisor` starts `BullX.Runtime.SignalRouting.Cache` before
Gateway source listeners can publish inbound Signals. The existing application
ordering already starts `BullX.Gateway.SourceSupervisor` after
`BullX.Runtime.Supervisor`; keep that invariant.

Configure Gateway to use the Runtime boundaries:

```elixir
config :bullx, :gateway,
  router: BullX.Runtime.SignalRouting.Router,
  consumer_delivery: BullX.Runtime.ConsumerDelivery
```

### Cache refresh

On startup, `Cache` loads enabled rule rows whose Agent Principals are currently
active when `route_action = deliver_agent`, validates them through the Ecto
schema and matcher normalizer, and stores a sorted snapshot. Sink routes do not
depend on Agent state. If the table does not exist during pre-migration boot,
it logs a warning and starts with an empty snapshot. If a table exists but
contains invalid data that should be impossible through the writer, startup
fails so routing does not silently use partial rules.

On writer calls:

1. The database transaction commits.
2. `Cache.refresh_all/0` reloads the full enabled rule set.
3. New Gateway publishes use the new snapshot.
4. Already enqueued `DeliveryIntent` jobs keep their embedded route decision.

Principal or Agent status changes that affect Agent eligibility must also call
`SignalRouting.Cache.refresh_all/0` after commit. The Router performs a final
active-Agent check before building `deliver_agent` intents, and `RouteConsumer`
repeats the check as the last safety boundary.

Direct SQL edits are not a supported live-update path. Operators should use the
writer API or restart Runtime after manual repair.

## Error and failure behavior

Router failures preserve Gateway's publish semantics:

| Failure | Behavior |
| --- | --- |
| Cache process unavailable | Router returns `{:error, :signal_routing_unavailable}`; Gateway reports `:router_unavailable`. |
| No matching rules | Router returns `{:ok, []}`. |
| Terminal blackhole route wins | Router emits one blackhole `RouteIntent` and suppresses other destinations for that Signal publish. |
| Matching Agent route references a disabled Agent after cache load | Router skips the candidate; `RouteConsumer` also discards stale queued jobs with safe telemetry. |
| Rule deleted after enqueue | `RouteConsumer` writes `rule_id = NULL`, keeps `rule_key`, and continues. |
| Decision insert conflicts with existing `{signal_id, destination_key}` | `RouteConsumer` returns the existing row and treats the retry as successful. |
| Route decision insert fails due to PostgreSQL outage | `RouteConsumer` returns `{:retry, reason}` so Oban retries. |

Route writes must preserve root-cause information in telemetry or
`decision_metadata` without storing raw provider payloads, secrets, LLM prompts,
or sink-only content.

## Security, privacy, and governance

Routing is delivery to a destination, not authorization to perform external
effects. A routed Agent still needs AuthZ and Governance checks before creating
risky Work, invoking a Capability, emitting an Intent, or producing an external
Effect.

Route rules must not store:

- provider access tokens, app secrets, OAuth codes, or private keys;
- raw provider webhook bodies;
- LLM API keys or provider options;
- prompt text or model ids;
- user-edited display names as identity proof.

Rules may match trusted adapter-normalized source fields, channel-local actor
fields, and adapter-normalized routing facts. They must not use display strings
as identity proof.

Sink decisions must not construct or persist `content_snapshot`. This is a
privacy and semantic boundary: a route record explaining that BullX dropped a
Signal must not contain the content that no Agent received.

Telemetry may include rule id, rule key, route action, destination key, input
mode, sink kind, adapter, channel id, scope id, thread id, Signal id, Signal
occurrence key, Agent Principal id, actor bot flag, and failure class. Telemetry
must not include message text, assistant output, raw provider payloads,
credentials, private adapter config, or sink-only content.

## Alternatives considered

### Preserve Dynamic Runtime Targets

The legacy plan routed one inbound Signal to one `runtime_target`, with target
kinds such as `agentic_chat_loop` and `blackhole`. That shape is useful for a
bot runtime but wrong for BullX AgentOS. It makes target selection central,
stores AI behavior near route rows, and cannot naturally express one Signal
being routed to several Agents with different runtime implementations. The
current design keeps dynamic rules and cache refresh but replaces targets with
Agent and Sink destinations.

### Use Admission as the top-level model

Admission is a useful concept when an Agent decides whether a Signal enters
active attention. It is too narrow for the Router. The user-facing stories are
about sending Signals to handlers: Feishu messages to Quant, multiple support
bots to Support, GitHub webhooks to workflow Agents, timer Signals to
decision-tree Agents, and news pushes to two research Agents. Some destinations
are sinks, and a blackhole is not an Agent. `Signal -> Route -> Destination`
fits those stories directly.

### Put routing rules inside Gateway

Gateway already calls a Router, so adding rules directly under Gateway would
look local. It would also violate the Gateway design: Gateway must not resolve
Principals, choose Agents, create route decisions, or understand Work and
Governance. Runtime owns the Router implementation because routing is a
business decision about destination delivery.

### Broadcast every Signal to every Agent

Broadcasting would avoid a rule engine, but it would leak visibility, increase
LLM and runtime cost, and force every Agent prompt to rediscover organization
responsibility. Routing exists to decide where a Signal should go before Agent
runtime starts.

### Store route rules in `BullX.Config`

`BullX.Config` works for source lists and typed runtime settings, but route
rules need Agent foreign keys, indexes, constraints, idempotent updates, and
auditable rows. A PostgreSQL table is the simpler durable contract.

### Use a generic predicate language

Cedar, JSON logic, regexes, or arbitrary predicate ASTs would make the first
router more expressive. They would also enlarge validation, testing, security,
and operator-debugging cost before real routing pressure exists. Fixed columns
plus adapter-normalized routing facts cover the current chat, webhook, timer,
and news routing stories without letting route rules parse raw payloads.

## Risks and tradeoffs

- No code fallback means a fresh Installation does not reply to inbound chat
  until an Agent Principal and a default inbound Agent route exist. This is
  intentional because work should not happen under a code-only subject.
- `drop_signal` is global and terminal only when it is the highest ranked
  matching rule. This keeps blackhole behavior explainable but does not express
  "block only Agent A while delivering to Agent B." That narrower suppression
  behavior should be designed later if real pressure appears.
- Storing content snapshots for Agent deliveries duplicates normalized payload
  data for every delivered Agent. The duplication is acceptable because Gateway
  does not own a Signal log and each Agent delivery needs its own ingress
  context. Blackhole decisions store the routing snapshot only.
- Route refresh is local to the current node. This matches the current
  configuration and cache coherence model. A later multi-node design can add
  PostgreSQL notifications or an explicit control-plane broadcast.
- Actor Principal matching is intentionally omitted from the first slice. This
  keeps broad source routing independent of Principal storage. If presence
  matching is added later, `unresolved` still requires an attempted Principal
  lookup and must fail closed on storage errors.
- Adapter-normalized routing facts avoid raw payload predicates, but they shift
  provider-specific routing vocabulary into adapters. This keeps the Router
  boring and auditable at the cost of requiring adapters to expose stable facts
  deliberately.
- Route decision idempotency uses `{signal_id, destination_key}` instead of
  `delivery_key`. This preserves Gateway route-at-publish semantics for
  repeated external occurrences because `delivery_key` intentionally identifies
  a concrete delivery and does not include `Signal.id`.

## Implementation handoff

### Goal

Implement Runtime-owned signal routing that converts Gateway Signals into
durable route decisions through Gateway Mailbox delivery intents.

### Context pointers

- `AGENTS.md`
- `docs/design-docs/SignalsGateway.md`
- `docs/design-docs/Principal.md`
- `docs/design-docs/AuthZ.md`
- `docs/design-docs/LLMProvider.md`
- `docs/design-docs/Configuration.md`
- `docs/design-docs/Plugins.md`
- `lib/bullx/gateway.ex`
- `lib/bullx/gateway/router.ex`
- `lib/bullx/gateway/consumer_delivery.ex`
- `lib/bullx/gateway/delivery_intent.ex`
- `lib/bullx/gateway/signal.ex`
- `lib/bullx/gateway/signal_delivery_worker.ex`
- `lib/bullx/principals.ex`
- `lib/bullx/principals/agent.ex`
- `lib/bullx/runtime/supervisor.ex`
- `test/bullx/gateway/publish_test.exs`

### Constraints

- Keep Gateway transport-only.
- Use Route as the top-level concept, not Admission.
- Use Agent Principals and system sinks, not Runtime targets.
- Generate UUID primary keys with `BullX.Ecto.UUIDv7`.
- Use native PostgreSQL enums for route action, Agent input mode, and sink kind.
- Keep runtime route data free of Elixir code, module names, ASTs, prompts,
  model aliases, and secrets.
- Store no Gateway-owned inbound Signal table.
- Match against `RoutingContext`, not raw `Signal.data`.
- Do not assume or accept nested CloudEvents `extensions`.
- Require `signal_type` for every route rule.
- Do not store content snapshots for sink decisions.
- Do not add record-only sink decisions.
- Do not add actor Principal matching in the first slice.
- Keep route matching deterministic and testable with fixed columns and one
  exact routing fact match.
- Do not add dependencies.
- Do not change Gateway Mailbox semantics.
- Do not modify plugin source config semantics.

### Tasks

1. Add routing migrations and schemas.
   - Owns: `priv/repo/migrations/*_create_signal_routing_tables.exs`,
     `lib/bullx/runtime/signal_routing/rule.ex`,
     `lib/bullx/runtime/signal_routing/route_decision.ex`.
   - Depends on: none.
   - Acceptance: enums, rules, decisions, constraints, indexes, destination
     keys, and UUIDv7 primary keys match this design.
   - Verify: focused schema tests.

2. Add `RoutingContext`.
   - Owns: `lib/bullx/runtime/signal_routing/routing_context.ex`.
   - Depends on: task 1.
   - Acceptance: inbound and delivery outcome Signals project into the shared
     routing facts; adapter-normalized routing facts are loaded only from
     `data["routing_facts"]`, are string or string-array based, and nested
     `extensions` maps are rejected through Gateway Signal loading; sink
     snapshots omit content.
   - Verify: routing context tests.

3. Add the writer and cache.
   - Owns: `lib/bullx/runtime/signal_routing/writer.ex`,
     `lib/bullx/runtime/signal_routing/cache.ex`,
     `lib/bullx/runtime/signal_routing.ex`.
   - Depends on: tasks 1 and 2.
   - Acceptance: writer validates route rules, commits rows, refreshes cache
     after commit, permits the broad inbound Agent route shape, rejects
     all-Signal catch-alls, validates routing fact key/value pairs, and loads
     only enabled Agent routes for active Agents.
   - Verify: writer/cache tests.

4. Add matching.
   - Owns: `matcher.ex`.
   - Depends on: tasks 2 and 3.
   - Acceptance: matcher covers every fixed column, routing fact match, terminal
     drop rule, destination grouping, and `priority -> key` ordering.
   - Verify: matcher tests.

5. Implement the Gateway Router and route intent builder.
   - Owns: `router.ex`, `route_intent.ex`.
   - Depends on: task 4.
   - Acceptance: `resolve/1` returns valid `DeliveryIntent` structs, supports
     fan-out, emits terminal blackhole routes when they win, groups decisions by
     destination, returns `{:ok, []}` for no match, and returns an error when
     required routing dependencies are unavailable.
   - Verify: router tests plus existing Gateway publish tests with the Runtime
     router configured.

6. Implement Runtime consumer dispatch and route consumption.
   - Owns: `lib/bullx/runtime/consumer_delivery.ex`,
     `route_consumer.ex`.
   - Depends on: task 5.
   - Acceptance: Runtime dispatcher routes `signal_route_intent` jobs; route
     jobs insert idempotent `signal_route_decisions`; blackhole decisions stop
     after persistence and do not construct `content_snapshot`; Agent delivery
     decisions stop after persistence; deleted rules persist as `rule_id = NULL`;
     disabled Agents fail closed.
   - Verify: dispatcher, route consumer, and Oban retry/discard tests.

7. Wire runtime startup and configuration.
   - Owns: `lib/bullx/runtime/supervisor.ex`, `config/*.exs` if needed.
   - Depends on: tasks 3, 5, and 6.
   - Acceptance: signal routing cache starts under Runtime; Gateway uses the
     Runtime Router and Runtime ConsumerDelivery dispatcher; Gateway
     SourceSupervisor remains after Runtime startup.
   - Verify: application/supervisor tests or focused integration tests.

8. Add integration coverage.
   - Owns: `test/bullx/runtime/signal_routing/*`,
     relevant Gateway publish tests.
   - Depends on: tasks 1 through 7.
   - Acceptance: tests cover fan-out, terminal blackhole, default inbound Agent
     routes, no-match, actor bot matching, absent actors, outcome projection,
     routing fact matching, cache refresh, idempotent decision insert, disabled
     Agents, rule deletion after enqueue, invalid rule rejection, and sink-path
     omission of `content_snapshot`.
   - Verify: focused tests and `bun precommit`.

### Done when

- A matching Signal creates one Mailbox job per winning destination decision.
- A winning terminal blackhole route creates a durable `drop_signal` decision
  with no `content_snapshot` and no Agent runtime consumption.
- A no-match Signal returns no delivery intents and does not fail Gateway
  publish.
- A single Signal can deliver to multiple Agents with different input modes.
- Delivery outcome Signals project into `RoutingContext` without relying on
  inbound `data["event"]` paths.
- Updating rules through the writer changes routing for the next publish
  without restarting the VM.
- Disabling an Agent Principal refreshes the routing cache and prevents new
  Agent delivery; stale queued jobs still fail closed.
- Route rows contain no executable code, module names, model aliases, prompts,
  or secrets.
- Route rules can match adapter-normalized routing facts without parsing raw
  provider payloads.
- Gateway remains unaware of Route internals and actor Principal resolution.
- Focused Runtime/Gateway tests pass.
- `bun precommit` passes.

## Acceptance criteria

This design is implemented when:

1. `BullX.Runtime.SignalRouting.Router` satisfies `BullX.Gateway.Router` and
   returns valid `DeliveryIntent` structs.
2. `BullX.Runtime.ConsumerDelivery` satisfies `BullX.Gateway.ConsumerDelivery`
   and dispatches `signal_route_intent` jobs to SignalRouting.
3. `RoutingContext` supports Gateway inbound and delivery outcome carriers,
   adapter-normalized routing facts, and strict top-level CloudEvents extension
   attributes.
4. `signal_route_rules` and `signal_route_decisions` use UUIDv7 primary keys,
   native enum columns, JSONB object constraints, and the `{signal_id,
   destination_key}` decision idempotency key.
5. Rule matching supports fixed source, channel-local actor, actor bot, event,
   routing fact, action, and destination fields with deterministic
   `priority -> key` ordering.
6. Router fan-out can return several Agent delivery intents for one Signal.
7. A winning `drop_signal` route is terminal and suppresses other destinations
   for that Signal publish.
8. Sink route decisions do not construct or persist content snapshots.
9. The first slice does not support actor Principal matching. If a later design
   adds actor Principal presence, both `resolved` and `unresolved` presence
   matching require publish-time Principal lookup.
10. The routing cache reconstructs from PostgreSQL on restart, refreshes after
    writer commits, excludes inactive Agent destinations, and keeps sink routes
    independent of Agent state.
11. Agent delivery decisions store routing snapshots and content snapshots;
    sink decisions store routing snapshots only.
12. Every rule requires `signal_type`; default assistant behavior uses a
    default inbound Agent route for `com.agentbull.x.inbound.received`.
13. The implementation has no Jido dependency, no `runtime_targets`, no target
    kinds, no code-owned `main` fallback, no Router-level Admission model, no
    record sink, and no Gateway-owned Signal table.
