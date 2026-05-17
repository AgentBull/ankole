# EventBus matcher

EventBus matcher defines the route-decision contract between Event acceptance
and TargetSession handoff. It owns `RoutingContext` projection, route table
snapshots, Rust matcher behavior, Event Routing Rule priority, Blackhole
semantics, and scope/window key computation.

The matcher decides which single Event Routing Rule receives an accepted Event.
It does not execute Targets, create TargetSessions, append side-channel entries,
or persist business facts. Those responsibilities belong to
[EventBus core](./Core.md).

## RoutingContext

`RoutingContext` is a string-keyed JSON-neutral projection used only by the
matcher. It has no `Installation`, no `tenant_id`, no provider raw payload, and
no nested Event carrier.

The projection is:

```json
{
  "source": "event.source",
  "type": "event.type",
  "time": "event.time",
  "event": {
    "id": "event.id",
    "identity": {
      "source": "event.source",
      "id": "event.id"
    }
  },
  "channel": {
    "adapter": "data.channel.adapter",
    "id": "data.channel.id"
  },
  "scope": {
    "id": "data.scope.id",
    "thread_id": "data.scope.thread_id"
  },
  "actor": "data.actor",
  "refs": "data.refs",
  "reply_channel": "data.reply_channel",
  "routing_facts": "data.routing_facts"
}
```

The implementation builds a JSON map with actual values, not the literal strings
shown in the example. Event identity is the CloudEvents `(source, id)` pair.
Dedupe computation belongs to EventBus acceptance and does not enter the matcher
projection.

`RoutingContext` must not contain:

- `Installation` or `tenant_id`.
- Provider raw payload.
- `subject`.
- `dedupe_hash` or a composite dedupe key.
- CloudEvents extension attributes.
- `data.event` or `data.event.name`.
- `event_name` or `event_kind`.
- An Elixir module name derived from database strings.

## Routing table and matcher

Event Routing Rules use CEL expressions, but Elixir does not call a generic CEL
evaluator once per rule. The runtime boundary is a domain-specific Rust matcher
NIF.

Shared CEL compilation, boolean execution, and BEAM-to-JSON/CEL conversion
belong to the rule-engine support layer, not to EventBus. The shared Rust code
lives under `native/bullx_ext/src/rule_engine/cel.rs`, with Elixir wrappers
under `BullX.RuleEngine.CEL` and `BullX.RuleEngine.JSON`. EventBus-specific
route-table, priority, `RoutingContext`, diagnostics, and matched-rule behavior
belong in EventBus matcher code under the same `rule_engine` native boundary,
not in the shared CEL module.

The matcher contract is:

- Elixir supplies a route table snapshot and a `RoutingContext` JSON map.
- Rust owns route table compilation and evaluation.
- Rust may use `cel-rust` internally.
- Rust may implement route matcher custom functions inside Rust.
- Rust returns a matched rule id or `no_match`.
- Rust returns diagnostics suitable for telemetry.
- Rust treats a single rule's CEL evaluation error as a non-match for that rule
  and records safe diagnostics.
- Rust never receives provider raw payload.
- Rust evaluation is deterministic.

If route table compilation or evaluation can exceed normal BEAM scheduler
limits, the NIF must run as dirty CPU work.

`BullX.EventBus.RoutingTable` owns the in-memory route table snapshot. On
application boot, it loads active `event_routing_rules`, sorts them by
`priority ASC`, and gives the snapshot to the Rust matcher for compilation or
cache warmup. `EventBus.accept/2` routes against the most recent successfully
compiled snapshot.

The Event Routing Rule writer is the supported live-update path. After the
writer changes the database, it refreshes or rebuilds the `RoutingTable`
snapshot; the implementation may rebuild the full snapshot. Direct SQL edits
are not a live update path. They take effect only after an explicit refresh or
application restart.

Rule writers must reject saving or activating a rule whose `match_expr` cannot
compile. On application boot, if the active route table cannot compile, the
system must either fail fast or reject Event acceptance until a valid snapshot
exists. Runtime evaluation errors for one rule are not compile failures; that
rule does not match for the current Event and telemetry records safe diagnostics.

## Event Routing Rules

Event Routing Rules are evaluated by numeric priority ascending. Smaller
priority values have higher priority. `priority` is globally unique across all
rows. Duplicate priority is invalid even when one duplicated row is inactive.
There is no tie-breaker and no implicit specificity ordering.

The database enforces priority uniqueness with a unique constraint on
`priority` across all Event Routing Rule rows. Rule editor drag-sort operations
must reorder priorities transactionally. The writer may use a deferrable unique
constraint when supported, or a temporary-priority rewrite strategy.

The first matching rule is terminal. EventBus does not perform route fan-out. A
fallback or wildcard rule is legitimate, but it is still ordered only by numeric
priority and is reached only when higher-priority rules do not match.

An Event Routing Rule declares:

- `match_expr`: the CEL expression evaluated against `RoutingContext`.
- `target_type`: the target category.
- `target_ref`: the target id for non-Blackhole targets.
- `scope_fields`: the ordered `RoutingContext` field paths used to compute
  `scope_key`.
- `window_type` and `window_ttl_seconds`: the TargetSession reuse window policy.

`target_type` is a PostgreSQL native enum with these values:

- `ai_agent`
- `workflow`
- `external_agent_harness`
- `blackhole`

Blackhole is the only current terminal drop target name. Its behavior is:

- Return `accepted_ignored`.
- Create no TargetSession.
- Append no side-channel entry.
- Create no Oban job.
- Emit telemetry.
- Do not continue to fallback or lower-priority rules.

Non-Blackhole targets require `target_ref`. Blackhole uses `target_ref = null`.
Blackhole rules do not create TargetSessions and do not use scope or window
values, but the writer stores neutral defaults to keep the schema simple:

- `scope_fields = []`
- `window_type = 'new_per_event'`
- `window_ttl_seconds = null`

EventBus ignores those neutral defaults on the Blackhole path.

## Scope and window policy

Scope policy uses an ordered fields list, not CEL. Rules store
`scope_fields text[]`.

Example:

```text
["channel.adapter", "channel.id", "scope.id", "scope.thread_id"]
```

Each field path must be validated against allowed `RoutingContext` paths. The
design allows stable scalar paths such as:

- `source`
- `type`
- `event.id`
- `event.identity.source`
- `event.identity.id`
- `channel.adapter`
- `channel.id`
- `scope.id`
- `scope.thread_id`
- `actor.id`
- `actor.principal_ref`
- `reply_channel.adapter`
- `reply_channel.channel_id`
- `reply_channel.scope_id`
- `reply_channel.thread_id`
- `routing_facts.<key>`

`routing_facts.<key>` is allowed only for explicit normalized facts. Scope policy
must not use provider raw payload or `subject`.

Every scope field must resolve to an existing scalar JSON value or `null`.
Missing paths, objects, and lists are scope resolution errors. For a matched
non-Blackhole rule, a scope resolution error returns
`%BullX.EventBus.AppendFailed{code: :scope_resolution_failed}` with safe
diagnostics. Rule authors should make `match_expr` require `routing_facts` keys
that also appear in `scope_fields`.

EventBus computes `scope_key` from the ordered `scope_fields` and their values.
The encoding must preserve field order, distinguish `null` from an empty string,
and avoid delimiter ambiguity. The implementation uses ordered `[field, value]`
pairs encoded as canonical JSON arrays, not string concatenation.

Example:

```json
[
  ["channel.adapter", "feishu"],
  ["channel.id", "default"],
  ["scope.id", "chat_or_room_or_domain_scope"],
  ["scope.thread_id", null]
]
```

Window policy supports two `window_type` values:

- `new_per_event`
- `rolling_ttl`

For `new_per_event`, `window_key` uses the Event identity's canonical JSON
encoding, such as `[["event.source", source], ["event.id", id]]`.
`window_ttl_seconds` must be `null`.

For `rolling_ttl`, `window_key = "rolling"`. `window_ttl_seconds` is required
and positive. EventBus reuses the same active TargetSession only while
`expires_at` has not passed. On append, EventBus extends or refreshes
`expires_at` to `min(now + window_ttl_seconds, inserted_at + 24 hours)`.

This design does not define fixed bucket windows or arbitrary window
expressions.
