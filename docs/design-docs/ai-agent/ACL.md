# AIAgent ACL

AIAgent ACL is the narrow access gate used by AIAgent runtime before it starts
conversation work, executes an AIAgent-owned command, or executes a tool call.
The first implementation deliberately keeps the model small: a triggering
Principal either has no access, ordinary access, or privileged access to one
AIAgent. AIAgent ACL reuses `BullX.AuthZ` grants and does not introduce a
separate policy engine, group table, grant table, audit subsystem, sandbox
subsystem, or Budget subsystem.

The ACL answers one implementation question: can the triggering Principal run
this AIAgent operation with this required access tag? If not, the v1 elevation
strategy is always `deny`.

## Scope

This design defines:

- AIAgent ACL access levels and operation access tags.
- The AuthZ resource and action names used to resolve access for one AIAgent.
- ACL gates for conversation starts, AIAgent-owned commands, tool schema
  rendering, and tool execution.
- `agents.profile.ai_agent.acl.elevation_strategy` v1 semantics.
- How runtime resource limits become ACL decisions without becoming an ACL
  storage model.
- Failure behavior for denials, malformed profile data, missing Principals, and
  AuthZ errors.
- The boundary with Agentic Loop core, Principal, AuthZ, EventBus,
  TargetSession, Capability, Budget, Skill, and Conversation / Message records.

This design does not define:

- Tool registry, ToolSet expansion, tool schema rendering internals, or tool
  execution functions.
- Capability governance, sandbox policy, Budget accounting, audit-log storage,
  approval workflow, or external action execution.
- Fine-grained application action tags beyond `ordinary` and `privileged`.
- Human approval, ticket approval, custom DAG escalation, or automatic approval
  state machines.
- Principal creation, external identity binding, group membership, or AuthZ
  grant persistence.
- EventBus routing, Event Routing Rules, TargetSession side-channel storage,
  Channel Adapter transport behavior, Workflow Node contracts, or Command
  Target routing.

## Design Decision

The first AIAgent runtime uses an AIAgent-level ACL instead of a general
Capability governance system. The current product need is to control which
Principals can make a given AIAgent perform ordinary operations or privileged
operations. Approval flows, resource quota storage, sandbox governance,
high-risk external action records, and Capability execution rules remain in the
subsystem designs that own those behaviors.

Tool risk is represented at the tool boundary. When a risk is primarily caused
by the operation's purpose, split it into separate tools rather than hiding a
complex parameter policy inside one broad tool. For example,
`bi.query_public_metric` can be ordinary while `bi.query_revenue` is
privileged; `artifact.write_report` can be ordinary while `repo.apply_patch` is
privileged.

ToolSet is a configuration and expansion layer, not an authorization subject.
Agentic Loop core expands enabled ToolSets, computes each tool's effective
access tag, and passes the tag to AIAgent ACL. A Skill may later point to a
ToolSet, but a Skill remains a knowledge asset and does not grant execution
power.

Resource limits do not become a v1 ACL subsystem. The runtime that owns a task,
domain, or Budget-like counter decides when continuing would exceed the local
limit and marks that continuation operation as `privileged`. The ACL then
allows or denies the operation using the same access comparison as every other
operation.

## Access Model

AIAgent ACL has three access levels:

| Access level | Meaning |
| --- | --- |
| `none` | The triggering Principal cannot execute operations on this AIAgent. |
| `ordinary` | The triggering Principal can execute ordinary operations. |
| `privileged` | The triggering Principal can execute ordinary and privileged operations. |

AIAgent ACL has two v1 operation access tags:

| Operation tag | Meaning |
| --- | --- |
| `ordinary` | Conversation starts, low-risk AIAgent-owned commands, and low-risk tool calls. |
| `privileged` | Deletion, external writes, sensitive data queries, permission-changing actions, resource-limit overruns, or other operations that require higher trust. |

Authorization is a simple comparison:

```text
required tag = ordinary     -> ordinary or privileged access allows
required tag = privileged   -> privileged access allows
otherwise                   -> deny
```

There are no explicit deny grants, deny priority rules, or multi-level policy
resolution inside AIAgent ACL. `ordinary` and `privileged` are the v1 action
groups. Additional tags such as `finance_read`, `customer_write`,
`external_send`, or `quota_overrun` require a later design, but the runtime
shape stays the same: the operation declares its required tag and ACL compares
that tag against the triggering Principal's resolved access level.

## AuthZ Mapping

AIAgent ACL reuses `BullX.AuthZ`. It does not add ACL-specific groups, grants,
grant priorities, decision caches, or evaluators.

For an AIAgent whose Agent Principal id is `agent_principal_id`, AIAgent ACL
uses this AuthZ resource:

```text
ai_agent:<agent_principal_id>
```

AIAgent ACL defines two AuthZ actions for that resource:

| AuthZ action | ACL meaning |
| --- | --- |
| `use` | Allows ordinary operations. |
| `use_privileged` | Allows privileged operations and implies ordinary operations. |

Access resolution is ordered:

```text
if BullX.AuthZ.authorize(caller, "ai_agent:<agent_principal_id>", "use_privileged", context) == :ok
  access = privileged
else if BullX.AuthZ.authorize(caller, "ai_agent:<agent_principal_id>", "use", context) == :ok
  access = ordinary
else
  access = none
```

The `context` argument contains only safety facts explicitly computed at the
enforcement point, such as input mode, Connected Realm id, channel kind, web
session presence, or other documented request facts. AIAgent ACL must not pass a
raw CloudEvent, provider payload, private Agent profile fields, full tool
arguments, secrets, or private policy data into AuthZ context.

Operator configuration for ordinary or privileged AIAgent access writes normal
AuthZ grants:

```text
group sales     -> resource ai_agent:<agent_principal_id>, action use
group ops-admin -> resource ai_agent:<agent_principal_id>, action use_privileged
```

AuthZ decides whether a Principal is allowed for one resource/action/context
request. AIAgent ACL interprets the AuthZ result as `none`, `ordinary`, or
`privileged`, then compares that access level with the operation tag.

## Operation Classes

AIAgent runtime assigns an access tag before executing an operation. The LLM
does not decide access tags.

### Conversation

Starting an AIAgent model/tool loop is an `ordinary` operation unless the
AIAgent profile explicitly marks the entry point as `privileged`. An
unauthorized caller may produce a safe denial outcome, but the runtime must not
start a model call or tool loop.

Observed input that is stored only as context and does not start a model/tool
loop does not need the conversation operation ACL gate. If observed input
triggers model execution, a tool call, a visible reply, Work creation, or another
follow-up operation, the triggering operation must pass ACL before it starts.

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
the runtime still denies execution when the triggering Principal lacks the
required access level.

### Resource-Limit Continuation

Resource limits are converted into operation tags by the runtime that owns the
limit decision. AIAgent ACL does not count usage, settle cost, or persist quota
state.

Example:

```text
ResearchAgent receives a research Event
  -> caller has ordinary access to ai_agent:<research_agent_principal_id>
  -> the enabled web research ToolSet exposes ordinary search tools
  -> task runtime tracks provider usage against the task's token cap
  -> continuing deep search would exceed that cap
  -> runtime marks "continue deep research" as privileged
  -> AIAgent ACL denies because caller lacks privileged access
  -> the AIAgent stops deep search and produces a report from gathered evidence
```

This is a normal convergence path, not an infrastructure failure. Once a
resource-limit continuation is denied, the loop must not repeatedly retry the
same denied operation. It should move to the next safe step available to the
Target, such as summarizing gathered evidence, stopping work with a safe
explanation, or creating a later business record when another design explicitly
allows it.

Advertising spend, external API spend, storage quota, runtime, and model-cost
limits use the same shape: the owning runtime decides that continuing is above
the local limit, marks the continuation operation as `privileged`, and lets ACL
allow or deny the operation.

## Elevation Strategy

`agents.profile.ai_agent.acl.elevation_strategy` defines behavior when the
triggering Principal lacks the required access level. The only v1 value is:

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
audit log. Subsystems that perform high-risk external actions, approval,
Capability execution, Budget settlement, or policy outcomes own their own
business records.

EventBus and TargetSession are delivery and execution-window runtime layers.
ACL denial is not an EventBus routing decision and does not change Event Routing
Rule matching. ACL denial does not ask EventBus to retry unless AuthZ, storage,
or another infrastructure dependency failed.

## Failure Behavior

ACL denial is a business-understandable denial, not infrastructure failure.

Rules:

- Normal ACL denial must not return an error that causes TargetSession retry.
- Missing, disabled, or malformed caller Principal data resolves to access level
  `none`.
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
Principal's access level before starting a model loop, running an
AIAgent-owned command, rendering tool schemas, or executing a tool call.

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
  Capability governance, Budget accounting, and audit storage in their owning
  designs.

### Tasks

1. Add ACL profile validation.
   Owns `agents.profile.ai_agent.acl.elevation_strategy`.
   Accept only `"deny"`. Invalid values block model calls and tool execution
   and fail with safe diagnostics.

2. Add the AIAgent access resolver.
   Resolve `none | ordinary | privileged` from the triggering Principal, Agent
   Principal id, and documented request context. Check `use_privileged` before
   `use`; no grant, disabled Principal, missing Principal, invalid request, or
   AuthZ denial fails closed.

3. Gate conversation starts and AIAgent-owned commands.
   Check ACL before starting the model/tool loop and before executing an
   AIAgent-owned command. An unauthorized caller must not trigger a model call.
   An ordinary caller can run ordinary conversation commands and cannot run
   privileged commands.

4. Gate tool schema rendering and tool execution.
   Filter provider tool schemas by the caller's access level before rendering
   the model request. Re-check the selected tool before execution. A forged,
   replayed, or otherwise unauthorized privileged tool call is denied and
   recorded as a structured tool-result error when the loop can continue.

5. Add a resource-limit-to-tag test path.
   Use a Core or task-runtime test double that marks a continuation operation as
   `privileged` after a local limit would be exceeded. Verify that an ordinary
   caller is denied, the same denied operation is not retried, and the loop
   enters a safe convergence path.

### Stop and Ask

Stop implementation and ask for a design decision if the work requires:

- A non-`deny` elevation strategy.
- A formal operation tag beyond `ordinary` and `privileged`.
- ApprovalRequest, ticket, custom DAG, or automatic approval behavior inside v1.
- ACL-specific authorization tables, cache processes, policy languages, or
  evaluators.
- Resource quotas, sandbox policy, audit logging, or Capability governance as a
  runtime dependency of AIAgent ACL.

## Done When

- AIAgent ACL uses AuthZ grants on `ai_agent:<agent_principal_id>` with actions
  `use` and `use_privileged`.
- The access resolver returns `none`, `ordinary`, or `privileged` and fails
  closed for AuthZ denials and invalid Principal states.
- Conversation starts, AIAgent-owned commands, and tool calls are checked before
  execution.
- Provider tool schema rendering exposes only tools the current caller can run.
- Tool execution performs a second ACL check.
- Insufficient access always uses `elevation_strategy = "deny"` in v1.
- Resource limits can become privileged continuation operations without adding
  a resource-quota subsystem to ACL.
- Denied operation outcomes can be recorded through Conversation / Message or
  command/tool result shapes without a new audit-log table.
- Agentic Loop core owns ToolSet expansion and tool-loop details, while AIAgent
  ACL owns the ordinary / privileged authorization gate.
- `bun precommit` passes before implementation is merged.
