# Command Target

Command Target is the first-class Target implementation for normalized command
Events that do not require an AIAgent model loop. It lets canonical command names
such as `command` and `status`, with localized slash aliases normalized by
Channel Adapters, run through EventBus, Event Routing Rules, TargetSession,
Principal, AuthZ, Governance, Capability, and Channel Adapter boundaries without
making AIAgent runtime a generic command dispatcher.

Not every command Event routes to Command Target. Canonical command name `new`
remains an AIAgent conversation command by default because it mutates
Conversation, Message branch, generation lease, prompt context, or model/tool
recovery state. The default slash token `/new` and localized aliases such as
`/新会话` both normalize to `data.routing_facts.command_name = "new"` when an
adapter emits `bullx.command.invoked`. Provider-native command Events may route
directly to `target_type = "ai_agent"` when the command name is owned by the
AIAgent catalog. If the adapter does not normalize the provider input as
`bullx.command.invoked`, the same command may still reach AIAgent as addressed
message text and be detected by the AIAgent fallback parser.

## Scope

This design defines:

- `target_type = "command"` as a v1 EventBus Target type.
- Command Target dispatch through stable `target_ref` values and code-owned
  command registries.
- Canonical command names and localized slash alias normalization.
- The input contract between TargetSession side-channel entries and command
  handlers.
- Command handler output, visible reply, idempotency, failure, and close
  behavior.
- Command category ownership across Command Target, AIAgent, Workflow,
  Approval/Governance, and admin policy.
- Routing examples and focused implementation tests.

This design does not define concrete command business tables, the full AuthZ
policy catalog, provider-specific rendering, AIAgent Conversation internals, or
the matcher DSL syntax.

Concrete system commands are defined in `SystemCommands.md`. The current system
command handler catalog contains only `/command` and `/status`; `/command`
renders the broader code-owned EventBus command catalog, including cataloged
AIAgent control commands that route through command fallback.

## Target contract

Command Target is a Target implementation, not EventBus core logic. EventBus
matches one Event Routing Rule, creates or reuses one TargetSession, appends one
side-channel entry, and invokes the Target. It does not parse command text,
choose command handlers, decide command authorization, send visible replies, or
write command business facts.

`target_type = "command"` selects the Command Target implementation. `target_ref`
selects a stable code-owned command handler id, command namespace, or command
router id. Examples:

- `bullx.system.command_list`
- `bullx.system.status`
- `bullx.command_router.default`

The dispatch path uses stable `target_type` and code-owned registries. It must
not concatenate database strings into Elixir module names and must not resolve
arbitrary modules from `target_ref`.

Command Target uses the same callback shape as every other Target:

```elixir
Target.handle_event(invocation, side_channel_entry) ::
  :ok | {:error, term()}
```

For one-shot commands, the command handler requests
`BullX.EventBus.TargetSession.close/1` after successfully processing the current
entry, then returns `:ok`. The TargetSession loop advances progress after
`Target.handle_event/2` returns `:ok` and applies the close safe point defined
by EventBus Core.

## Input contract

Command Target reads normalized command Events, usually
`type = "bullx.command.invoked"`. `bullx.command.invoked` is a normalized Event
type, not a closed enum of concrete command names. Concrete names and arguments
come from adapter normalization, routing facts, command registry entries, and
command-specific design.

Command names used for routing are canonical English ids. Localized slash tokens
are adapter-normalization aliases. For example, in a Chinese locale `/状态` and
`/status` both normalize to `data.routing_facts.command_name = "status"`.
Command Target receives the canonical name and does not parse or resolve
localized command text.

A command handler receives at least:

- `invocation.target_session_id`
- `invocation.event_routing_rule_id`
- `invocation.target_type`
- `invocation.target_ref`
- `side_channel_entry.id` as `target_session_entry_id`
- accepted CloudEvents `id`, `source`, `type`, and `time`
- accepted CloudEvents `data.channel`, `data.scope`, `data.actor`, and
  `data.reply_channel`
- `data.routing_facts.command_name`
- normalized command args or a safe command-argument reference when the command
  design exposes them
- Principal evidence and actor evidence passed through EventBus invocation

Command Target may read `data.content` only as normalized command input defined
by the adapter and command design. EventBus does not parse slash text from
`data.content`; command text parsing belongs to adapter normalization or a
command handler. Bearer credentials, provider interaction tokens, activation
codes, login codes, and private callback values must not become routing facts or
logs; a command design that needs sensitive arguments must define a safe
argument-reference path or another explicitly protected input shape.

## Handler output

A command handler may produce:

- `:ok`
- a visible reply outbound request through the Channel Adapter boundary
- a business record, audit record, or diagnostic record
- a safe error response
- a follow-up Event, Work, ApprovalRequest, or Capability call when the specific
  command design allows it

Command Target does not call an LLM by default. A command that needs judgment,
tool reasoning, long-running Work planning, or conversation state should target
AIAgent, Workflow, or another explicit Target boundary instead of hiding a model
loop inside a generic command handler.

Command Target does not write Conversation or Message records unless the
specific command is explicitly an AIAgent conversation command and the write is
performed through an AIAgent-owned service. Generic system, info, auth,
governance, and admin commands must not edit AIAgent Conversation internals.

Command Target does not directly call provider-specific Feishu, Slack, Telegram,
Discord, or other adapter modules. Visible replies use `data.reply_channel` and
the Channel Adapter outbound boundary, such as `deliver/4`, or the stream
boundary when a command-specific design requires streaming. The adapter owns
provider rendering and transport errors; the command handler owns whether a
reply should be sent and what safe content it contains.

Visible replies must use a stable idempotency key. The normal key is derived
from:

- `target_session_entry_id`
- `target_ref`
- normalized command name
- the stable identity of `reply_channel`

If a provider or adapter cannot guarantee exactly-once send, Command Target
still provides a stable outbound idempotency key and records duplicate-safe
business or diagnostic state. EventBus does not guarantee exactly-once command
execution.

## Failure behavior

A command business failure is part of command semantics. The handler records the
business, diagnostic, or audit outcome and returns `:ok` so TargetSession
progress can advance. Examples include denied admin command, unsupported command
arguments, missing reply capacity, or a safe user-facing validation error.

Infrastructure failure returns `{:error, reason}` so TargetSession retry and
at-least-once delivery semantics apply. Examples include database outage,
adapter registry outage, command registry corruption, or a retryable dependency
failure before the handler can record a durable outcome.

Safe diagnostics and audit records must not contain raw CloudEvents, provider
payloads, credentials, bearer reply handles, access tokens, stream chunks, or
unbounded message content.

Unknown command names are not handled by Command Target. Routing can send them
to an explicit command route, route them to Blackhole, or let EventBus command
fallback try the matching addressed-message route. If fallback cannot find an
addressed route, EventBus ignores the command and writes a warning log. The
system command handlers must not become a catch-all command interpreter.

## Routing and TargetSession policy

Command routing uses ordinary Event Routing Rules. Do not create a second
command routing pipeline outside EventBus. A command rule normally matches:

- `type = "bullx.command.invoked"`
- `data.routing_facts.command_name`
- optional `data.routing_facts.command_namespace`
- optional actor, channel, scope, or Connected Realm facts

Command rules usually use higher priority than generic AIAgent message rules so
provider-native `/command` or `/status` Events do not fall into an AIAgent model
loop. The first matched rule remains terminal. EventBus does not fan out one
command Event to multiple Targets.

System command rules are code-owned built-ins, not PostgreSQL setup data. They
are merged into the runtime `RoutingTable` snapshot ahead of database-owned
rules by using reserved negative priorities. Database-owned command rules still
use ordinary positive `event_routing_rules.priority` values and the same matcher
path.

Command rules use the same scope policy as other Event Routing Rules. Built-in
system commands request `BullX.EventBus.TargetSession.close/1` after handling the
entry; the worker then applies the EventBus runtime idle grace before closing the
TargetSession.

When `bullx.command.invoked` matches no explicit command route, EventBus runs a
code-owned command fallback after the direct matcher miss. The fallback changes
only the routing context type to `bullx.im.message.addressed` and tries the same
route table again. If the shadow addressed context matches, EventBus reuses that
route's Target and TargetSession scope while preserving the original
`bullx.command.invoked` CloudEvent in the side-channel entry. This lets
AIAgent-owned slash commands such as `/stop` and `/steer` use the same source
and conversation routing as addressed messages without making Command Target a
generic AIAgent command dispatcher. If the shadow addressed context does not
match, EventBus ignores the command and writes a warning log.

If one command needs multiple business paths, Command Target expresses that
inside the handler by calling a service, writing a follow-up Event, creating
Work, creating an ApprovalRequest, or invoking a governed Capability. EventBus
does not make the same Event match multiple Targets.

## Adapter boundary

Command input may arrive through provider-explicit command surfaces or through
ordinary message transports. Provider-explicit slash commands, application
commands, UI commands, button callbacks, and interactive commands may be
normalized by Channel Adapters as `type = "bullx.command.invoked"`. A plain text
message that starts with `/` becomes a command Event only when the adapter's
attention policy and command grammar classify the leading token as addressed to
BullX. Ordinary text, paths, code snippets, and unaddressed group messages remain
normal message Events.

The adapter places routing-relevant command facts in `data.routing_facts`, such
as:

- `command_name`
- `command_namespace`
- `command_surface`
- `command_args_kind`
- `provider_command_id`
- `attention_reason`

The adapter remains transport-only for EventBus command Events. It does not
choose the handler, call Command Target, inspect routing rules, or write command
business facts for commands that enter EventBus.

Some commands are channel-adapter commands, not Command Target commands.
`/preauth` and `/webauth` are adapter-owned activation and login entry points
because they may need to run before Principal binding exists, may rely on
provider-private reply or interaction handles, and start at the provider channel
boundary. The adapter may handle those inputs directly through Principal/Auth
services and provider-safe replies instead of publishing
`bullx.command.invoked`. That adapter-local path is not a second EventBus
routing pipeline; it is part of channel setup and account binding.

Channel Adapters are not required to support provider-native slash commands. If
a provider source lacks command support, setup or UI should fail closed for that
feature, or ordinary provider messages may enter EventBus as normal message
Events and follow normal message rules.

Provider interaction tokens, callback URLs, ephemeral response handles, OAuth
codes, access tokens, and other bearer credentials must not enter
`reply_channel`, `routing_facts`, CloudEvents, Oban args, stream metadata,
telemetry, or logs. The adapter stores only a safe reference or adapter-private
handle.

Provider-native command redelivery must reuse stable CloudEvents `(source, id)`.
The adapter must not generate random UUIDs or receive timestamps as Event ids
for command occurrences.

## Command categories

System and info commands belong to Command Target. The current concrete system
commands are `/command` and `/status`, as defined in `SystemCommands.md`. They
do not call a model and do not write Conversation. They may send a safe visible
reply when `reply_channel` is usable.

Channel activation and login commands such as `/preauth` and `/webauth` belong
to Channel Adapters by default. They may create auth/preauth/login records or
return safe setup instructions through adapter-owned transport flows. They must
use Principal, AuthZ, and Connected Realm facts and do not call a model.

AIAgent conversation command names such as `new`, `reset`, `compress`, `retry`,
`undo`, and `title` remain owned by AIAgent runtime by default, because they
mutate Conversation, Message branch, generation lease, prompt context, or
model/tool recovery state. Default slash tokens such as `/new` and `/compress`,
and localized aliases such as `/新会话` or `/压缩`, normalize to the same
canonical command names before routing. A normalized AIAgent conversation
command may route directly to `target_type = "ai_agent"`. If one of these
commands routes to Command Target instead, the only valid handling is an
explicit design-approved delegation through an AIAgent-owned command service.
Command Target must not directly edit Conversation internals unless AIAgent
exposes that service boundary.

Run-control commands such as `/stop`, `/queue`, and `/steer` may be Command
Target only if AIAgent or ChildRun exposes explicit interrupt, queue, or steer
APIs and a later design assigns that route to Command Target. Otherwise
AIAgent-owned run-control commands route to `target_type = "ai_agent"` or use
the addressed-message fallback. Command Target must not reach into TargetSession
worker internals.

Governance commands such as `/approve` and `/deny` may be Command Target or an
Approval Target. Business facts belong to ApprovalRequest and Governance, not to
EventBus.

Admin commands such as `/restart`, `/reload`, `/update`, and `/debug` require
explicit AuthZ/admin policy. They do not call a model. Diagnostics must be safe
and redacted.

## Routing examples

### Example A: `/status`

Event:

- `type = "bullx.command.invoked"`
- `data.routing_facts.command_name = "status"`

Routing Rule:

- high priority
- `target_type = "command"`
- `target_ref = "bullx.system.status"`
- command-scoped TargetSession lane

Command Target:

- returns minimal runtime status through `reply_channel`
- calls `BullX.EventBus.TargetSession.close/1`
- does not call a model
- does not write Conversation

### Example B: database-owned non-system command

Event:

- `type = "bullx.command.invoked"`
- `data.routing_facts.command_name = "diagnose"`

Routing Rule:

- `target_type = "command"`
- `target_ref = "bullx.command_router.default"`
- positive database-owned priority, lower precedence than built-in system
  command priorities unless explicitly reordered

Command Target:

- resolves the command through the code-owned command registry or router
- verifies actor, Principal, and AuthZ evidence required by that command
- writes safe diagnostic or business records
- uses the Channel Adapter outbound boundary
- does not call a model

### Example C: `new` command aliases

Provider-native `/new` and localized `/新会话` normalize to canonical
`command_name = "new"`. That command may route directly to
`target_type = "ai_agent"` and be consumed by the AIAgent command handler. Plain
text `/new` or `/新会话` may also reach AIAgent as a message and be handled by
AIAgent's built-in command detection through the same canonical command catalog.

Do not route `/new` to a generic system command handler unless that handler
delegates through an AIAgent-owned Conversation reset boundary.

### Example D: `compress` command aliases

Provider-native `/compress` and localized aliases such as `/压缩` normalize to
canonical `command_name = "compress"`. This is an AIAgent conversation command
because it changes future prompt context through summary overlay state. It may
route directly to `target_type = "ai_agent"` after adapter normalization, or
reach AIAgent as plain text when the adapter does not normalize the provider
input as `bullx.command.invoked`.

Do not route `compress` to a generic system command handler. Command Target may
delegate only through the AIAgent-owned compression boundary; it must not write
summary Messages or move Conversation leaves directly.

## Non-goals

- Do not create a second command routing pipeline outside Event Routing Rules.
- Do not add Event fan-out.
- Do not let EventBus parse slash command text.
- Do not put command business logic into EventBus matcher.
- Do not make adapters choose Targets or inspect routing rules.
- Do not make Command Target bypass Principal, AuthZ, Governance, Budget, or
  Capability policy.
- Do not make Command Target own AIAgent Conversation internals.
- Do not require every Channel Adapter to support provider-native slash
  commands.
- Do not require EventBus to guarantee exactly-once command execution. Target
  and command handler side effects remain idempotent.

## Implementation handoff

### Goal

Implement Command Target as a first-class EventBus Target so normalized command
Events can run without entering AIAgent model loops while preserving EventBus,
Channel Adapter, AIAgent, Workflow, Principal, AuthZ, Governance, and Capability
boundaries.

### Context pointers

- `docs/Architecture.md` defines the EventBus, Event Routing Rule,
  TargetSession, Target, AIAgent, Workflow, Principal, Skill, Capability, and
  business-fact boundaries.
- `docs/design-docs/eventbus/Core.md` defines Event acceptance, TargetSession,
  Target invocation, close/fail helpers, and EventBus non-semantics.
- `docs/design-docs/eventbus/Matcher.md` defines `RoutingContext`, priority,
  first-match terminal behavior, `routing_facts`, and scope policy.
- `docs/design-docs/eventbus/Persistence.md` defines EventBus target type,
  `target_ref`, routing rule, TargetSession, and side-channel persistence.
- `docs/design-docs/eventbus/ChannelAdapter.md` defines command normalization
  and outbound delivery transport boundaries.
- `docs/design-docs/eventbus/SystemCommands.md` defines the concrete current
  system command catalog.
- `internals/design-docs/drafts/AgenticLoopCore.md` defines AIAgent-owned
  Conversation command ownership, including canonical command names and
  localized aliases.
- `internals/design-docs/drafts/AgenticLoopContextCompressionAndCaching.md`
  defines the AIAgent-owned `compress` command outcome and summary overlay
  boundary.
- `docs/design-docs/Principal.md` and `docs/design-docs/AuthZ.md` define
  Principal evidence and authorization boundaries.

### Constraints

- Use `target_type = "command"` for Command Target rules.
- Resolve `target_ref` through a code-owned Command Target registry.
- Do not derive Elixir module names from database strings.
- Accept normalized command Events through EventBus and TargetSession; do not
  add a separate command intake path.
- Keep Command Target one-entry callback behavior aligned with
  `Target.handle_event/2`.
- Default one-shot commands request `close/1` and return `:ok` after durable
  records or visible-reply requests are written.
- Keep business failures durable and return `:ok`; return `{:error, reason}`
  only for infrastructure or retryable runtime failure.
- Send visible replies only through Channel Adapter outbound or stream
  boundaries.
- Keep AIAgent Conversation internals behind AIAgent-owned services.

### Tasks

1. Add `command` to the EventBus target type contract.
   - Owns: EventBus enum/schema/writer validation and docs.
   - Check: route rules can store `target_type = "command"` with a stable text
     `target_ref`.

2. Implement the Command Target registry and dispatch.
   - Owns: command target module, registry, handler behavior, and tests.
   - Check: dispatch uses stable ids, rejects unknown handlers safely, and does
     not resolve modules from database strings.

3. Implement baseline system/info handlers.
   - Owns: `bullx.system.command_list` and `bullx.system.status`.
   - Check: `/command` lists the current EventBus command catalog and `/status`
     does not require a valid AIAgent profile or model spec.

4. Implement code-owned system command routes.
   - Owns: built-in route catalog and `RoutingTable` snapshot merge.
   - Check: `/command` and `/status` routes are not written to PostgreSQL, use
     reserved negative priorities, and still match through the same Rust matcher
     and TargetSession path as database-owned routes.

5. Add outbound reply handoff.
   - Owns: transport-neutral command replies and adapter handoff tests.
   - Check: visible replies go through Channel Adapter `deliver/4` or stream
     boundary and use stable idempotency keys.

6. Add AIAgent command boundary tests.
   - Owns: cross-doc behavior tests where AIAgent runtime exists.
   - Check: canonical AIAgent command names such as `new` and `compress`, plus
     localized aliases such as `/新会话` and `/压缩`, remain AIAgent-owned and may
     route directly to `target_type = "ai_agent"` or use EventBus command
     fallback to the matching addressed route unless explicitly delegated
     through an AIAgent command service.

### Done when

Focused tests cover:

- `target_type = "command"` dispatches through a stable Target registry, not
  dynamic module lookup.
- `bullx.command.invoked` with `command_name = "status"` reaches Command Target
  and does not call AIAgent or a model provider.
- One-shot Command Target calls `close/1`; TargetSession progress advances after
  `Target.handle_event/2` returns `:ok`.
- Duplicate provider command Event returns EventBus duplicate at acceptance, or
  Target redelivery does not duplicate visible replies because Command Target
  uses a stable idempotency key.
- `/command` and `/status` still work when an AIAgent profile is invalid or a model
  spec cannot resolve.
- Adapter-produced `routing_facts.command_name` is used only as a routing fact;
  EventBus does not parse `data.content` slash text.
- Command Target visible replies go through the Channel Adapter boundary, not
  provider-specific modules.
- Canonical AIAgent command names such as `new` and `compress`, plus localized
  aliases such as `/新会话` and `/压缩`, remain AIAgent-owned, can route directly
  to `target_type = "ai_agent"` or use EventBus command fallback to the matching
  addressed route, and are delegated through Command Target only by explicit
  design; generic Command Target does not mutate Conversation internals directly.
- Unauthorized admin command writes safe diagnostic/audit records and returns
  `:ok`; infrastructure failure returns `{:error, reason}`.

Verification commands:

```bash
mix format --check-formatted
# focused tests for EventBus command dispatch, TargetSession close, adapter
# command normalization, outbound reply idempotency, and AIAgent command boundary
MIX_ENV=test mix compile --warnings-as-errors
bun precommit
```

## Changelog

- Added `command` Target type.
- Clarified normalized `bullx.command.invoked`.
- Clarified adapter command normalization boundary.
- Moved system/info commands outside the AIAgent model loop.
- Clarified that `/preauth` and `/webauth` are channel-adapter commands by
  default.
- Kept AIAgent Conversation commands inside AIAgent runtime, including direct
  `target_type = "ai_agent"` routing, unless delegated through an explicit
  AIAgent command service.
- Added routing examples and focused tests.
