# AIAgent ACL

AIAgent ACL is the narrow access gate used by AIAgent runtime before it starts
conversation work, executes an AIAgent-owned command, or executes a tool call.
The first implementation deliberately keeps the model small: a triggering
Principal either can or cannot access one AIAgent. `ordinary` and `privileged`
are operation tags used by commands, ToolSets, tools, and runtime continuations;
they do not describe Principal-to-Agent access. AIAgent ACL reuses `BullX.AuthZ`
grants and does not introduce a separate policy engine, group table, grant
table, audit subsystem, sandbox subsystem, or Budget subsystem.

The ACL answers two implementation questions: can the triggering Principal
invoke this AIAgent at all, and if the operation is tagged `privileged`, does the
Principal also have the extra privileged-operation grant? If either required
check fails, the v1 elevation strategy is always `deny`.

## Scope

This design defines:

- The AIAgent access gate and operation access tags.
- The AuthZ resource and action names used to resolve access for one AIAgent.
- ACL gates for conversation starts, AIAgent-owned commands, tool schema
  rendering, and tool execution.
- `agents.profile.ai_agent.acl.elevation_strategy` v1 semantics.
- Failure behavior for denials, malformed profile data, missing Principals, and
  AuthZ errors.
- The boundary with Agentic Loop core, Principal, AuthZ, EventBus,
  TargetSession, ToolSet, Skill, Conversation / Message records, and future
  Capability or Budget accounting.

This design does not define:

- Tool registry, ToolSet expansion, tool schema rendering internals, or tool
  execution functions.
- Future Capability governance, sandbox policy, future Budget accounting,
  audit-log storage, approval workflow, or external action execution.
- Fine-grained application action tags beyond `ordinary` and `privileged`.
- Human approval, ticket approval, custom DAG escalation, or automatic approval
  state machines.
- Principal creation, external identity binding, group membership, or AuthZ
  grant persistence.
- EventBus routing, Event Routing Rules, TargetSession side-channel storage,
  Channel Adapter transport behavior, Workflow Node contracts, or Command
  Target routing.

## Design Decision

The first AIAgent runtime uses an AIAgent-level access gate plus a privileged
operation gate instead of waiting for a general future Capability governance
system. The current product need is to control which Principals can use a given
AIAgent, then add one extra check before privileged ToolSet, tool, command, or
runtime continuation operations. Approval flows, resource quota storage, sandbox
governance, high-risk external action records, and future Capability execution
rules remain in the subsystem designs that own those behaviors.

Tool risk is represented at the tool boundary. When a risk is primarily caused
by the operation's purpose, split it into separate tools rather than hiding a
complex parameter policy inside one broad tool. For example,
`bi_query_public_metric` can be ordinary while `bi_query_revenue` is
privileged; `artifact_write_report` can be ordinary while `repo_apply_patch` is
privileged.

ToolSet is a configuration and expansion layer, not an authorization subject.
Agentic Loop core expands enabled ToolSets, computes each tool's effective
access tag, and passes the tag to AIAgent ACL. A Skill may later point to a
ToolSet, but a Skill remains a knowledge asset and does not grant execution
power.

## Access Model

AIAgent ACL has one access decision:

| Decision | Meaning |
| --- | --- |
| allowed | The triggering Principal can invoke this AIAgent. |
| denied | The triggering Principal cannot invoke this AIAgent. |

Every allowed Principal can run ordinary AIAgent operations. AIAgent ACL has two
v1 operation access tags:

| Operation tag | Meaning |
| --- | --- |
| `ordinary` | Conversation starts, low-risk AIAgent-owned commands, and low-risk tool calls. |
| `privileged` | Deletion, external writes, sensitive data queries, permission-changing actions, or other operations that require higher trust. |

Authorization is a two-step check:

```text
agent access denied      -> deny
agent access allowed
  required tag = ordinary   -> allow
  required tag = privileged -> require privileged-operation grant
  otherwise                 -> deny
```

There are no explicit deny grants, deny priority rules, or multi-level policy
resolution inside AIAgent ACL. `ordinary` and `privileged` are operation tags,
not Principal-to-Agent access modes. Additional tags such as `finance_read`,
`customer_write`, or `external_send` require a later design, but the runtime
shape stays the same: the operation declares its required tag and ACL checks the
grant required by that tag.

## AuthZ Mapping

AIAgent ACL reuses `BullX.AuthZ`. It does not add ACL-specific groups, grants,
grant priorities, decision caches, or evaluators.

For an AIAgent whose Agent Principal id is `agent_principal_id`, AIAgent ACL
uses this AuthZ resource:

```text
ai_agent:<agent_principal_id>
```

The exact resource string is:

```text
resource = "ai_agent:" <> agent_principal_id
```

AIAgent ACL defines two AuthZ actions for that resource:

| AuthZ action | ACL meaning |
| --- | --- |
| `invoke` | Allows the Principal to access the AIAgent and run ordinary operations. |
| `invoke_privileged` | Allows privileged operations after the Principal has AIAgent access. |

The checks are ordered by operation:

```text
if BullX.AuthZ.authorize(caller, "ai_agent:<agent_principal_id>", "invoke", context) != :ok
  deny

if operation_tag == :ordinary
  allow
else if operation_tag == :privileged and
        BullX.AuthZ.authorize(caller, "ai_agent:<agent_principal_id>", "invoke_privileged", context) == :ok
  allow
else
  deny
```

The `context` argument contains only safety facts explicitly computed at the
enforcement point, such as input mode, Connected Realm id, channel kind, web
session presence, or other documented request facts. AIAgent ACL must not pass a
raw CloudEvent, provider payload, private Agent profile fields, full tool
arguments, secrets, or private policy data into AuthZ context.

Operator configuration writes normal AuthZ grants. Privileged operation access is
an extra grant, not a separate way to access the AIAgent:

```text
group sales     -> resource ai_agent:<agent_principal_id>, action invoke
group ops-admin -> resource ai_agent:<agent_principal_id>, action invoke
group ops-admin -> resource ai_agent:<agent_principal_id>, action invoke_privileged
```

AuthZ decides whether a Principal is allowed for one resource/action/context
request. AIAgent ACL first checks AIAgent access with `invoke`. It checks
`invoke_privileged` only for operations whose effective tag is `privileged`.

## Operation Classes

AIAgent runtime assigns an access tag before executing an operation. The LLM
does not decide access tags.

### Conversation

Starting an AIAgent model/tool loop is an `ordinary` operation. The runtime
requires the triggering Principal to have `invoke` on
`ai_agent:<agent_principal_id>`. An unauthorized caller may produce a safe denial
outcome, but the runtime must not start a model call or tool loop.

Observed input that is stored only as context and does not start a model/tool
loop does not need the conversation operation ACL gate. If observed input
triggers model execution, a tool call, a visible reply, Work creation, or another
follow-up operation, the triggering operation must pass ACL before it starts.

For this ACL design, model execution means the caller-visible AIAgent Core
generation path that can produce assistant output, tool calls, visible delivery,
Work, or another follow-up operation. Ambient brief generation and the ambient
intent recognizer are Agent-owned auxiliary observation calls defined by
`./AmbientAndEventMessages.md`. They do not use the ambient speaker as an ACL
caller, do not require the triggering Principal to pass the conversation ACL
gate, and do not grant permission for a later visible reply or tool call.

### Command

Every AIAgent-owned command has an access tag.

The default AIAgent-owned conversation commands are `ordinary` when they only
change the current Conversation branch, generation lease, prompt context, or
other local conversation runtime state while preserving durable evidence. A
command that deletes, rewrites, exports, changes permission, or triggers an
external side effect is `privileged`.

Command Target routing and external command routing are outside this design.
This design only defines how an AIAgent-owned command is gated after it enters
the AIAgent runtime.

### Tool Call

Each tool has an effective access tag computed by Agentic Loop core from the
enabled ToolSet configuration. AIAgent ACL consumes the computed tag.

The runtime applies ACL at two enforcement points:

1. Before provider request rendering, include only tool schemas whose effective
   access tag is allowed for the current caller.
2. Before tool execution, re-check the selected tool's effective access tag.

The second check is the hard boundary. If a model emits a tool call that was not
rendered into the provider request, or if a provider replays an old tool call,
the runtime still denies execution when the triggering Principal lacks AIAgent
access or the extra grant required by a privileged tool.

## Elevation Strategy

`agents.profile.ai_agent.acl.elevation_strategy` defines behavior when the
triggering Principal lacks AIAgent access or lacks the extra grant required by a
privileged operation. The only v1 value is:

```json
{
  "acl": {
    "elevation_strategy": "deny"
  }
}
```

`deny` means the runtime does not create an ApprovalRequest, does not open a
ticket, does not wait for a human, does not start a custom DAG, and does not keep
the TargetSession alive for escalation. The runtime returns a safe denial
outcome:

- A denied conversation operation does not call the model.
- A denied command writes a safe command or error result.
- A denied tool call writes a structured tool-result error, or stops the current
  loop when the relevant policy requires a terminal outcome.

Non-`deny` escalation strategies are outside v1. They require a separate design
that defines the approval or workflow contract and its durable records.

## Persistence Boundary

AIAgent ACL stores no ACL-specific business records. It consumes:

- `principals.id` and Principal status through `BullX.AuthZ`.
- AuthZ groups and permission grants through `BullX.AuthZ`.
- `agents.profile.ai_agent.acl.elevation_strategy` for the runtime's denial
  behavior.
- ToolSet-derived operation tags from Agentic Loop core.
- Explicit request context facts supplied by the enforcement point.

Conversation / Message records are sufficient v1 durable evidence for denied
AIAgent operations. A denied command, denied tool result, or safe conversation
startup denial can be represented in the conversation transcript or command
result shape owned by Agentic Loop core. This design does not require a separate
audit log. Subsystems that later perform high-risk external actions, approval,
future Capability execution, future Budget settlement, or policy outcomes own
their own business records.

EventBus and TargetSession are delivery and execution-window runtime layers.
ACL denial is not an EventBus routing decision and does not change Event Routing
Rule matching. ACL denial does not ask EventBus to retry unless AuthZ, storage,
or another infrastructure dependency failed.

## Failure Behavior

ACL denial is a business-understandable denial, not infrastructure failure.

Rules:

- Normal ACL denial must not return an error that causes TargetSession retry.
- Missing, disabled, or malformed caller Principal data fails the AIAgent access
  gate.
- AuthZ results `{:error, :forbidden}`, `{:error, :principal_disabled}`,
  `{:error, :not_found}`, and `{:error, :invalid_request}` fail closed.
- AuthZ or storage infrastructure failure may fail the current TargetSession
  through `BullX.EventBus.TargetSession.fail/2` with safe diagnostics.
- Malformed ACL profile data is an unrecoverable configuration error for the
  current operation. The runtime must fail the TargetSession with a safe reason
  and must not call the model or execute tools.
- User-visible denial text must be short and safe. It must not expose private
  policy, grant details, raw CloudEvents, tool arguments, provider payloads,
  secrets, or private profile fields.
- Denied tool execution writes a structured tool-result error when the loop can
  safely continue; otherwise the loop stops with a safe terminal outcome.
- Resource-limit denials are not retried as the same operation unless new
  caller authority, new configuration, or new business input arrives through a
  later Event or explicit runtime state change.

## Implementation Handoff

### Goal

Implement an AIAgent ACL gate so Agentic Loop core can check the triggering
Principal's AIAgent access before starting a model loop, running an
AIAgent-owned command, rendering tool schemas, or executing a tool call. For
operations tagged `privileged`, the gate also checks the extra privileged
operation grant.

### Context Pointers

- `docs/design-docs/ai-agent/Core.md`
- `docs/design-docs/ai-agent/SlashCommands.md`
- `docs/design-docs/AuthZ.md`
- `docs/design-docs/Principal.md`
- `docs/design-docs/eventbus/Core.md`

### Constraints

- Reuse `BullX.AuthZ`; do not add ACL-specific group, grant, cache, evaluator,
  policy-language, or decision-cache storage.
- Do not let the LLM decide operation tags.
- Do not pass raw Events, provider payloads, full tool arguments, private policy
  data, or private Agent profile fields into AuthZ context.
- Support only `ordinary` and `privileged` access tags in v1.
- Support only `elevation_strategy = "deny"` in v1.
- Do not keep a TargetSession alive solely for approval or privilege escalation.
- Keep EventBus routing, TargetSession side-channel behavior, ToolSet expansion,
  future Capability governance, future Budget accounting, and audit storage in
  their owning designs.

### Tasks

1. Add ACL profile validation.
   Owns `agents.profile.ai_agent.acl.elevation_strategy`.
   Accept only `"deny"`. Invalid values block model calls and tool execution
   and fail with safe diagnostics.

2. Add the AIAgent access resolver.
   Resolve whether the triggering Principal can invoke the Agent Principal id
   under the documented request context. No `invoke` grant, disabled Principal,
   missing Principal, invalid request, or AuthZ denial fails closed.

3. Gate conversation starts and AIAgent-owned commands.
   Check ACL before starting the model/tool loop and before executing an
   AIAgent-owned command. An unauthorized caller must not trigger a model call.
   Any caller with `invoke` can run ordinary conversation commands; privileged
   commands additionally require `invoke_privileged`.

4. Gate tool schema rendering and tool execution.
   Filter provider tool schemas by AIAgent access and privileged-operation grant
   before rendering the model request. Re-check the selected tool before
   execution. A forged, replayed, or otherwise unauthorized privileged tool call
   is denied and recorded as a structured tool-result error when the loop can
   continue.

### Stop and Ask

Stop implementation and ask for a design decision if the work requires:

- A non-`deny` elevation strategy.
- A formal operation tag beyond `ordinary` and `privileged`.
- ApprovalRequest, ticket, custom DAG, or automatic approval behavior inside v1.
- ACL-specific authorization tables, cache processes, policy languages, or
  evaluators.
- Resource quotas, sandbox policy, audit logging, or future Capability governance
  as a runtime dependency of AIAgent ACL.

## Done When

- AIAgent ACL uses `invoke` on `ai_agent:<agent_principal_id>` as the Agent
  access gate.
- `invoke_privileged` is checked only as the extra grant for operations tagged
  `privileged`.
- The access gate fails closed for AuthZ denials and invalid Principal states.
- Conversation starts, AIAgent-owned commands, and tool calls are checked before
  execution.
- Provider tool schema rendering exposes only tools the current caller can run.
- Tool execution performs a second ACL check.
- Insufficient access always uses `elevation_strategy = "deny"` in v1.
- Denied operation outcomes can be recorded through Conversation / Message or
  command/tool result shapes without a new audit-log table.
- Agentic Loop core owns ToolSet expansion and tool-loop details, while AIAgent
  ACL owns Agent access and privileged-operation authorization.
- `bun precommit` passes before implementation is merged.
