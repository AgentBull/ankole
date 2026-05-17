# System Commands

System Commands are code-owned built-in Command Target handlers for safe BullX
runtime information. They are normalized command Events, routed by ordinary
Event Routing Rules in the runtime route-table snapshot, handled by
`target_type = "command"`, and do not enter an AIAgent model loop.

The current system command catalog contains only:

- `/command`
- `/status`

English canonical command names are always supported in every locale. Localized
command aliases may also be accepted by Channel Adapters and must normalize to
the same canonical command names before EventBus routing. For example, in a
Chinese locale both `/status` and `/状态` normalize to
`data.routing_facts.command_name = "status"`.

Adding another system command requires updating this document, the Command Target
registry, the code-owned built-in route catalog, localized alias catalog, and
focused tests.

## Scope

This design defines the concrete behavior for the current system commands:

- command names and handler ids;
- accepted input shape;
- visible reply content;
- runtime information sources;
- code-owned routing and TargetSession policy;
- authorization, failure, idempotency, and tests.

This design does not define auth/bootstrap commands such as `/preauth`, AIAgent
conversation commands such as `/new`, admin commands, provider-specific command
registration UX, or provider-specific reply rendering.

## Command Target boundary

System Commands are Command Target handlers. They follow
`CommandTarget.md`:

```elixir
Target.handle_event(invocation, side_channel_entry) ::
  :ok | {:error, term()}
```

They do not call an LLM, do not write Conversation or Message records, do not
mutate AIAgent runtime state, and do not inspect TargetSession worker internals.
They send visible replies only through `data.reply_channel` and the Channel
Adapter outbound boundary. They request
`BullX.EventBus.TargetSession.close/1` after a successful one-shot reply or a
safe no-reply result, then return `:ok`.

EventBus remains command-semantic agnostic. It accepts the Event, matches the
first route in the combined runtime snapshot by priority, appends the
TargetSession entry, and invokes the Target. It does not parse slash text,
choose command handlers, build reply text, decide command authorization, or send
outbound messages.

## Normalized input

Both system commands arrive as normalized command Events:

```text
type = "bullx.command.invoked"
data.routing_facts.command_name = "command" | "status"
```

Adapters may produce these Events from provider-native command surfaces or from
accepted slash-text messages. Ordinary messages that merely contain `/command` or
`/status` as text remain normal message Events unless the adapter command grammar
classifies the leading token as addressed to BullX.

`data.routing_facts.command_name` stores the canonical English command name,
not the localized input token. Adapter command normalization owns alias matching.
EventBus, RoutingTable, Matcher, TargetSession, and Command Target do not parse
localized slash text. Localized aliases must be unique inside the code-owned
command catalog for the active locale. English canonical names must remain
accepted even when the active locale is not English.

The command handlers may read:

- `invocation.target_session_id`
- `side_channel_entry.id`
- CloudEvents `id`, `source`, `type`, and `time`
- `data.channel`
- `data.scope`
- `data.actor`
- `data.reply_channel`
- `data.routing_facts.command_name`
- `data.routing_facts.command_surface`, when present
- `data.routing_facts.attention_reason`, when present

System commands do not require command arguments. If arguments are present, the
handler ignores them and returns the normal command response. Argument text must
not affect routing or handler selection.

## Registry

Command Target registry entries:

| Command | `target_ref` | Handler responsibility |
| --- | --- | --- |
| `/command` | `bullx.system.command_list` | Return the current system command catalog. |
| `/status` | `bullx.system.status` | Return minimal BullX runtime status. |

`target_ref` values are stable code-owned ids. Runtime dispatch must use the
Command Target registry and must not derive Elixir module names from database
strings.

## Routing

System command routing uses ordinary Event Routing Rules, but the current system
command rules are code-owned built-ins. They are merged into
`BullX.EventBus.RoutingTable` with active PostgreSQL `event_routing_rules` at
snapshot build time. The built-in rows are not persisted in PostgreSQL and are
not managed by `RuleWriter`.

Database-owned `event_routing_rules.priority` remains positive and starts at
`1`. The built-in system command rules use reserved negative priorities so they
sort ahead of configured database rules while keeping the combined runtime
snapshot globally unique by priority.

| Match | Priority | Target | Scope/window |
| --- | --- | --- | --- |
| `type == "bullx.command.invoked"` and `routing_facts.command_name == "command"` | `-20` | `target_type = "command"`, `target_ref = "bullx.system.command_list"` | one-shot, `new_per_event` |
| `type == "bullx.command.invoked"` and `routing_facts.command_name == "status"` | `-19` | `target_type = "command"`, `target_ref = "bullx.system.status"` | one-shot, `new_per_event` |

The first matched rule remains terminal. EventBus does not fan out the same
command Event to AIAgent or Workflow after a system command rule matches.

## `/command`

`/command` lists the currently available system commands. The response is a safe
visible reply and contains only commands defined in this document.

Required response content:

```text
Available commands:
/command - list available system commands
/status - show BullX runtime status, environment, and version
```

The command list is code-owned catalog data. It must not be inferred from
database routing rows, provider-native command registration state, or enabled
adapter capabilities. Provider-native command menus may use this catalog and its
localized aliases, but they are not the source of truth.

The handler:

1. Reads the current system command catalog from the code-owned registry.
2. Renders a plain text response.
3. Sends it through the Channel Adapter outbound boundary when
   `data.reply_channel` is usable.
4. Records a safe diagnostic no-reply result if no reply channel is available.
5. Requests TargetSession close.
6. Returns `:ok`.

## `/status`

`/status` returns minimal BullX runtime status. It is an operator-facing
diagnostic, not a full health report.

Required response content:

```text
BullX status:
running: yes
env: dev | test | prod
version: <mix project version>
```

`running` means the BullX OTP application is started and the Command Target is
handling the accepted Event. If the command handler is executing, the visible
response should report `running: yes`. If a lower-level status service is reused
outside EventBus and detects that the `:bullx` OTP application is not started, it
may return `running: no`; that state normally cannot produce an EventBus command
reply.

`env` is the current BullX runtime environment and must be one of `dev`, `test`,
or `prod`. Implementation may store this value in application environment during
configuration or expose it through a small compile-time/runtime info module. The
command handler must not call `Mix.env/0` at runtime, because Mix is not part of
normal release execution.

`version` is the BullX application version compiled from `mix.exs`
`project[:version]`. Implementation should read it from the OTP application spec,
such as `Application.spec(:bullx, :vsn)`, and convert it to a string. Do not
duplicate the version in command-specific configuration.

`/status` must not include secrets, database URLs, hostnames, IP addresses,
process ids, Erlang node names, stack traces, dependency versions, uptime,
database health, queue depth, route table contents, or AIAgent/model-provider
state.

The handler:

1. Reads runtime status from the system info provider.
2. Renders the minimal plain text response.
3. Sends it through the Channel Adapter outbound boundary when
   `data.reply_channel` is usable.
4. Records a safe diagnostic no-reply result if no reply channel is available.
5. Requests TargetSession close.
6. Returns `:ok`.

## Authorization and safety

`/command` and `/status` are safe informational commands. They may run with actor
evidence and without an activated Principal, as long as the adapter accepted the
command input and the Event Routing Rule matched. They do not grant capability
access, do not prove identity, do not create business records, and do not
authorize later side effects.

If a source or Installation policy later requires authenticated Principals for
system commands, that policy belongs in the command handler or AuthZ layer, not
in EventBus or the Channel Adapter. Unauthorized business outcomes should write
safe diagnostic or audit records when such records exist, send a safe denial
reply when allowed, request close, and return `:ok`.

## Idempotency

Visible replies use the Command Target idempotency rule from `CommandTarget.md`.
The idempotency key must include at least:

- `target_session_entry_id`
- `target_ref`
- normalized command name
- stable `reply_channel` identity

Provider redelivery of the same command occurrence should be deduped by
CloudEvents `(source, id)` at EventBus acceptance. If Target redelivery happens
after acceptance, the command handler must not send duplicate visible replies for
the same idempotency key.

## Failure behavior

Unknown command names are not handled by this document. Routing should either
miss them, route them to a separate command router design, or route them to
Blackhole according to the Installation route table. The system command handlers
must not become a catch-all command interpreter.

Business failures return `:ok` after safe handling. Examples:

- reply channel unavailable;
- source policy denies the command;
- renderer cannot produce provider-specific rich output and falls back to plain
  text.

Infrastructure failures return `{:error, reason}` only when retry may help or
the handler cannot safely finish:

- EventBus TargetSession close request fails unexpectedly;
- outbound adapter returns a retryable transport failure and the command handler
  chooses to rely on Target retry;
- system info provider cannot read the application spec because the runtime is in
  an invalid state.

Safe errors and diagnostics must not include raw CloudEvents, provider payloads,
credentials, reply bearer handles, or unbounded message content.

## Implementation handoff

### Constraints

- Do not add a second command routing pipeline.
- Do not parse slash text in EventBus.
- Do not make Channel Adapters execute `/command` or `/status` directly.
- Do not call AIAgent runtime or model providers.
- Do not write Conversation or Message records.
- Do not expose detailed dependency health or sensitive runtime metadata in
  `/status`.
- Do not call `Mix.env/0` from runtime command handlers.

### Tasks

1. Add system command registry entries.
   - Owns: Command Target registry.
   - Check: `bullx.system.command_list` and `bullx.system.status` resolve through
     stable ids.

2. Implement `/command`.
   - Owns: system command handler and reply rendering.
   - Check: reply lists exactly `/command` and `/status`.

3. Implement `/status`.
   - Owns: system info provider and system command handler.
   - Check: reply includes `running`, `env`, and `version`; version comes from the
     OTP application spec compiled from `mix.exs`.

4. Add code-owned built-in routes for the two system commands.
   - Owns: system command route catalog and `RoutingTable` snapshot merge.
   - Check: built-in routes match `bullx.command.invoked` by
     `routing_facts.command_name`, target Command Target, use one-shot session
     policy, sort ahead of PG rules, and are not written to
     `event_routing_rules`.

5. Add localized command alias normalization.
   - Owns: code-owned system command alias catalog and adapter command parser.
   - Check: English `/command` and `/status` remain accepted in every locale;
     Chinese `/命令` and `/状态` normalize to canonical `command` and `status`.

6. Add focused tests.
   - Owns: Command Target/system command tests.
   - Check: system commands do not call AIAgent, model providers, Conversation
     services, or provider-specific modules.

### Done when

Focused tests cover:

- `/command` returns exactly the current system command catalog.
- `/status` returns `running`, `env`, and the `mix.exs` project version.
- Localized command aliases normalize to canonical English `command_name` values
  before EventBus routing.
- English `/command` and `/status` work even when the active locale is not
  English.
- `/status` works when AIAgent profile or model provider configuration is
  invalid.
- Both commands route through `target_type = "command"` and stable registry ids.
- Built-in system command routes are merged from code, use reserved negative
  priorities, and do not create PostgreSQL routing rows.
- Both commands request `TargetSession.close/1` and return `:ok` on successful
  handling.
- Duplicate Target redelivery does not duplicate visible replies.
- EventBus does not parse slash text from `data.content`.
- Channel Adapters do not execute `/command` or `/status` directly.
- Visible replies go through the Channel Adapter outbound boundary.

Verification commands:

```bash
mix format --check-formatted
# focused tests for system command registry, /command, /status, idempotency,
# TargetSession close, and AIAgent/model-provider isolation
MIX_ENV=test mix compile --warnings-as-errors
bun precommit
```

## Changelog

- Added the current system command catalog.
- Defined `/command`.
- Defined `/status`.
- Added localized system command aliases while keeping English canonical
  commands always supported.
- Clarified runtime env and version sources.
- Clarified that system command routes are code-owned built-ins merged into the
  runtime route-table snapshot.
- Kept system commands inside Command Target and outside AIAgent runtime.
