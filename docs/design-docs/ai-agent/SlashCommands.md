# AIAgent Slash Commands

AIAgent slash commands are Conversation-local control inputs owned by the
AIAgent runtime. They can change the active Conversation, branch position,
generation lease, prompt context, or current Agentic Loop recovery state, but
they are not ordinary user turns and must not enter provider dialogue as normal
user text. EventBus, TargetSession, Channel Adapters, LLMProvider, and Workflow
do not own the business semantics of these commands.

This document defines the current AIAgent-owned command catalog, normalization
rules, control operation contract, active-generation behavior, safety
rules, and implementation handoff for `/new`, `/compress`, `/retry`, `/steer`,
`/stop`, and `/undo`.

## Scope

This design covers:

- AIAgent-owned slash command ownership boundaries.
- Slash token, localized alias, and canonical command-name normalization.
- The rule that slash command inputs and command responses are not Agent durable
  Messages.
- Generation coordination metadata and generated Message metadata required for
  recovery.
- Active-generation interaction with generation leases, tool calls, visible
  output, and late provider or tool results.
- Current behavior for `new`, `compress`, `retry`, `steer`, `stop`, and `undo`.
- The boundary with Agentic Loop ACL, compression, and core Conversation runtime
  behavior.

This design does not define:

- EventBus-wide command routing semantics.
- System commands such as `/command` and `/status`.
- Channel activation, login, preauth, web auth, or provider-private commands.
- CLI lifecycle hooks, worktree lifecycle, operator-console commands, prompt
  editor commands, or command-palette UI.
- Workflow, Node, External Agent Harness, SubAgent runtime, or admin commands.
- Context compression algorithms; `/compress` calls the compression design's
  manual handoff.

## Ownership Boundary

An AIAgent owns only the commands that mutate its own Conversation state, branch
state, generation lease state, prompt context, or current Agentic Loop recovery
state. The current AIAgent-owned catalog is:

| Canonical command | Default slash token | Localized aliases | Default access | Active-generation behavior |
| --- | --- | --- | --- | --- |
| `new` | `/new` | `/新会话` | ordinary | Preempt and cancel the current generation. |
| `compress` | `/compress` | `/压缩` | ordinary | Safe no-op or diagnostic while a generation is active. |
| `retry` | `/retry` | none | ordinary | Safe no-op or diagnostic while a generation is active. |
| `steer` | `/steer <prompt>` | none | ordinary | Attach a steering note to the next tool result; do not interrupt. |
| `stop` | `/stop` | none | ordinary | Preempt and stop the unfinished turn. |
| `undo` | `/undo` | none | ordinary | Safe no-op or diagnostic while a generation is active. |

Default English tokens are always accepted. Localized aliases normalize to the
same canonical command name before authorization, execution, or testing. Default
tokens and localized aliases cannot be removed without updating this design and
the focused tests.

`bullx.command.invoked` may route directly to `target_type = "ai_agent"` when
the normalized command name belongs to this AIAgent catalog. In that case the
AIAgent Target consumes the Event as command control input and must not write a
Conversation Message for the command input or response.

System commands such as `/command` and `/status` are Command Target handlers. If
an adapter normalizes one of those inputs to
`type = "bullx.command.invoked"` and an Event Routing Rule routes it to
`target_type = "command"`, the command does not enter an AIAgent runtime.
Channel activation and login commands such as `/preauth` and `/webauth` are
adapter-owned entry points by default because they may run before Principal
binding and may require provider-private reply context.

A generic Command Target must not act as the default delegate for AIAgent-owned
commands in v1. If a later design assigns an AIAgent command to a Command Target,
that Command Target must call an AIAgent-owned command service and must not
directly edit Conversation internals, write summary Messages, move a
Conversation leaf, or modify generation leases.

## Normalization And Detection

Channel Adapters may normalize provider-native command surfaces into
`type = "bullx.command.invoked"` with command facts under
`data.routing_facts`:

```json
{
  "command_name": "steer",
  "command_token": "/steer",
  "command_surface": "slash_text"
}
```

Adapters are transport-only at this boundary. They may match a provider command
surface, normalize aliases, and pass the accepted CloudEvent to EventBus. They
do not decide whether an AIAgent command is authorized, do not inspect
Conversation state, and do not execute the command.

Full command arguments do not belong in `data.routing_facts`. A command handler
that needs arguments reads them from normalized content or from a
command-design-owned safe argument shape after routing has selected the owning
Target.

When an ordinary text Event reaches an AIAgent and its leading text contains an
AIAgent-owned slash token that was not adapter-normalized, the AIAgent runtime
must run the same canonical catalog detection. Adapters for mention-gated IM
surfaces may also normalize a provider mention followed by a bare known command
word, such as `@Agent retry`, into `bullx.command.invoked` with
`command_surface = "mention_text"`. Detection is deterministic:

- Only a slash token at the beginning of the message is recognized.
- A bare command word is recognized only on provider mention surfaces and only
  when it is an exact known command token. Commands that do not take arguments
  must not consume a following natural-language sentence.
- A token-like string in the middle of ordinary text is not a command.
- Text after the token becomes command arguments.
- `/steer` requires a non-empty prompt.
- Alias matching produces a canonical command name before ACL, routing handoff,
  or command execution.
- Unknown leading slash tokens are not ordinary user text in v1. The AIAgent
  returns a safe command response or diagnostic without calling the model or
  executing tools. Unknown slash tokens are never privileged commands.

Only this design or an explicit AIAgent command configuration surface may add
aliases for this catalog.

## Control Operation Contract

AIAgent slash commands are control-plane inputs handled inside the AIAgent
runtime boundary. Their module placement does not make them part of the Agent
durable transcript.

A slash command input is not persisted as a `conversation_messages` record. A
command response is a transport-visible control response and is not persisted as
a `conversation_messages` record. Neither enters provider input, compression
coverage, retry target selection, undo exchange selection, or ordinary assistant
reply history. When the response is only status feedback, the outbound content
kind is `control_notice`; adapters may render it as a provider-native system or
tooltip-style message, and adapters without that surface degrade it to text.
When a command has visible progress and a later terminal state, the outbound
content kind is `progress_notice`; adapters with updateable message surfaces may
render and edit one progress message, and adapters without that surface degrade
to ordinary text.

The runtime records only the durable state that a command actually changes:

- `new` closes the current Conversation and creates a fresh active Conversation.
- `compress` may write a `kind = summary` Message through the compression
  design's normal summary path.
- `retry` may mark generated Messages as superseded, move
  `current_leaf_message_id`, and start a replacement generation.
- `stop` may cancel the active generation lease and recover stale generating
  output.
- `undo` may mark generated Messages as undone and move
  `current_leaf_message_id`.
- `steer` is an in-flight control hint. It is consumed by the active runtime
  loop when possible and is not durable Conversation history.

Command handlers may emit a safe command response when a usable `reply_channel`
exists. The response is fixed, content-free beyond the command result, and must
not include prompt text, steering text, raw CloudEvents, provider payloads,
credentials, private policy data, or reply bearer handles.

Branch-affecting commands may also request provider-visible cleanup through the
same `reply_channel`. If the Channel Adapter has previously returned a provider
message id for an assistant output and supports outbound `recall`, the AIAgent
may send a best-effort `recall` delivery for that provider message. Recall is a
presentation cleanup only. `current_leaf_message_id`, Message metadata, and
generation lease state remain the durable truth; a failed or unsupported recall
must not roll back the command transaction.

## Runtime Metadata

Slash commands reuse the Conversation generation lease as the active-generation
control point. They do not introduce a command queue table, and they do not store
slash command input history inside the lease object.

The lease object only records which generation attempt may still commit output:

```json
{
  "lease_id": "018f...",
  "owner_source_type": "target_session_entry",
  "owner_source_id": "018f...",
  "source_message_id": "018f-user-or-introspection",
  "started_at": "2026-05-18T14:35:00Z",
  "heartbeat_at": "2026-05-18T14:36:00Z",
  "expires_at": "2026-05-18T14:45:00Z",
  "cancelled_at": null,
  "cancellation_reason": null
}
```

An active lease has an owner, `expires_at > now`, and no `cancelled_at`. An owned
active lease additionally matches the runner's `lease_id`. An available lease is
empty, expired, or cancelled. Slash command input history, command response
state, and transport diagnostics do not live on
`conversations.generation`. Durable command effects live on the records they
actually mutate.

Lease TTL, heartbeat interval, and max runtime defaults are defined by Core.
Slash commands may cancel or replace a lease through the normal Core lease
contract, but command handlers do not choose independent lease timing defaults.

`steer` is intentionally weaker than a durable Message. Its prompt is an
in-flight control hint for the active runtime loop. Logs, telemetry, command
responses, and diagnostics must not copy that text. If the active loop cannot
consume the hint before generation ends or the runtime restarts, the hint may be
lost instead of being replayed from durable Conversation history.

Generated assistant, tool, and error Messages must include content-free
generation metadata so `retry` and `undo` do not require a turns table:

```json
{
  "generation": {
    "lease_id": "018f-lease",
    "source_message_id": "018f-user-or-introspection",
    "source_type": "target_session_entry",
    "source_id": "018f-entry-or-command",
    "root_assistant_message_id": "018f-assistant"
  }
}
```

`lease_id` identifies the generation attempt that produced the Message.
`source_message_id` points to the user-like Message that triggered this Agentic
Loop. `source_type` is `target_session_entry`, `ambient_batch`, or
`command_retry`. `source_id` is the entry id, batch idempotency key, or command
entry id. `root_assistant_message_id` points to the first assistant
Message produced by the generation; later tool, assistant, and error Messages
from the same generation reuse it.

Branch-affecting commands mark old generated Messages with content-free
`metadata.branch_effect` evidence:

```json
{
  "branch_effect": {
    "state": "superseded",
    "command": "retry",
    "command_entry_id": "018f...",
    "at": "2026-05-18T14:35:00Z"
  }
}
```

`state` is `superseded`, `undone`, or `interrupted`. `command` is the canonical
command name that created the marker, such as `retry`, `undo`, `stop`, or `new`.
`command_entry_id` points to the durable command entry when one exists. The
renderer primarily follows `current_leaf_message_id`; `branch_effect` is durable
evidence and a recovery aid, not a separate branch index.

## Transaction Pattern

Every command handler begins with the same transaction pattern:

1. Start an `Ecto.Multi` or database transaction.
2. Lock the active Conversation row for `{agent_principal_id, conversation_key}`.
3. Re-read `current_leaf_message_id` and `generation` under the same lock.
4. Run the command-specific mutation.
5. Commit before any model call, command response, or long-running tool work.

Command handlers do not call the model inside the command transaction. If a
command starts or restarts generation, it first commits branch and lease state,
then starts the normal AIAgent generation runner with an explicit source id.

## Authorization And Safety

Every AIAgent-owned command passes through the Agentic Loop command ACL gate
before execution. The current catalog uses the `ordinary` operation tag because
the commands only change the current AIAgent Conversation branch, generation
lease, or prompt context. Durable evidence is the state changed by the command,
not a Conversation Message that represents the command.

A command requires the `privileged` operation tag or a separate design if it
would:

- physically delete evidence;
- export content;
- change permissions;
- trigger an external side effect;
- mutate another Conversation, AIAgent, Principal, Connected Realm, Work, or
  business record;
- act outside the current AIAgent Conversation boundary.

Authorization starts from a current active Principal. Channel actor resolution
belongs to Principal AuthN, and permission checks belong to AuthZ. Disabled
Principals fail closed before command execution. The command service records a
safe denial or diagnostic outcome through telemetry or command response, does
not execute command effects, and returns
success to TargetSession progress unless an infrastructure failure prevents safe
completion.

V1 does not define per-command AuthZ actions. The command catalog maps each
command to the same ACL operation tags used elsewhere: the current commands are
`ordinary`; a later privileged command uses the existing AIAgent ACL
`invoke_privileged` check through `docs/design-docs/ai-agent/ACL.md` after the
caller has passed the Agent `invoke` gate. Adding a separate action such as
`command.retry` or `command.stop` requires a design update because it changes the
AuthZ surface.

Telemetry and logs are content-free. They may include command name, result,
ids, duration, safe reason code, provider or model ids, and lease state. They
must not include user prompt text, steering text, raw CloudEvents, provider
payloads, credentials, tool result content, private policy data, or reply bearer
handles.

## Active Generation Rules

The generation lease is the active-turn control point. Slash commands have three
active-generation modes:

- **Preemptive:** `new` and `stop` may cancel the current generation lease.
  The running Agentic Loop must re-check the lease and active Conversation state
  before committing assistant, tool, or error Messages, before starting visible
  output, and before outbound delivery.
- **Deferred in-loop:** `steer` does not cancel the lease, interrupt the
  current tool call, or create a new user turn. It records a note for the next
  tool result in the same live Agentic Loop when the runtime can consume it.
- **Non-preemptive:** `compress`, `retry`, and `undo` do not preempt an active
  generation. While one exists, they return a safe command response or
  diagnostic and end; the user may retry after generation finishes or after
  `/stop`.

If a provider call has already been sent and cannot be cancelled, the AIAgent may
discard the response. If a tool side effect has started, cancellation behavior
belongs to the tool or future Capability boundary. The AIAgent runtime owns
transcript safety: late results must not become current Conversation truth, and
side effects must not be duplicated by cancellation or retry handling.

## Command Catalog

### `new`

`new` closes the current active Conversation and creates a fresh active
Conversation for the same `agent_principal_id` and `conversation_key`. It means a
human starts a sibling Conversation, not a child continuation.

Handler behavior:

1. Lock the original active Conversation.
2. Set `ended_at = now()` and `metadata.end_reason = "new_session"`.
3. If a generation owner is active, set `generation.cancelled_at = now()` and a
   content-free cancellation reason.
4. Insert one fresh active Conversation with the same `agent_principal_id` and
   `conversation_key`, `current_leaf_message_id = null`, and empty generation
   metadata.
5. Do not call the model or execute tools for the command entry.

Late provider or tool output from the cancelled generation must fail the normal
lease and active-state recheck. It must not write into the fresh Conversation and
must not append ordinary branch output to the ended Conversation.

If the command Event has a usable `reply_channel`, `new` may send a safe command
response after commit. The response is not persisted as a Message.

### `compress`

`compress` manually triggers context compression before the next provider call.
It only changes the future provider-renderable history view. It does not delete
raw Messages, change Brain, Work, audit, or business records, or guarantee that
the next provider call will be under a safe budget.

Handler behavior:

1. Lock the active Conversation and resolve the raw active leaf. Do not use a
   summary Message as an append parent.
2. If a generation is active, return a safe no-op command response or diagnostic
   with `reason = "active_generation_present"`.
3. Otherwise emit a `progress_notice` with text equivalent to
   "正在压缩历史对话..." when a usable `reply_channel` exists.
4. Call the manual compression handoff with `conversation_id`,
   resolved raw active leaf id, triggering `target_session_entry_id`, and safe
   caller context.
5. Exclude the current inbound Message, generating Message, and incomplete tool
   pair from compression coverage.
6. If compression writes a summary, update the progress notice to text
   equivalent to "以上历史对话记录已被压缩"; channels without update support may send
   that terminal text as a separate degraded message.
7. If no provider-round interval can be compressed, update the same
   `progress_notice` to text equivalent to "没有可压缩的历史对话". The internal
   result may carry diagnostic `reason = "no_compressible_interval"`, but it
   must not also emit a separate `control_notice`.

The command never calls the main model or executes tools. Compression feedback
is not a `control_notice` because the command may take long enough to need an
updateable provider-visible surface.

### `retry`

`retry` retries the turn that produced the last eligible AI reply on the current
Conversation. It is not a new user turn. It sends the original user-like source
Message back through the normal AIAgent generation runner and removes the old
generated suffix from active branch rendering while preserving evidence.

The current design does not add a turns table. The runtime finds the retry
target from the Message tree and content-free generation metadata:

- The retry target is the last eligible assistant reply Message on the active
  branch.
- Eligible assistant replies exclude `kind = summary`, maintenance diagnostics,
  and `status = generating`.
- The turn source is the user-like Message that produced that assistant reply:
  `role = user, kind = normal` or `role = im_ambient, kind = introspection`.
- The turn includes generated assistant, tool, and error Messages after that
  source under the same generation source, through the retry target.

`retry` uses the Core-resolved active branch after summary overlay. It does not
treat the summary Message itself as an assistant reply and does not search inside
the covered interval hidden by the selected summary. If retry rewinds to a raw
Message that makes an existing summary incompatible, that summary is simply no
longer selected until a later compression writes a compatible summary.

Handler behavior:

1. Lock the active Conversation.
2. If a generation is active, return a safe no-op command response or diagnostic
   with `reason = "active_generation_present"`.
3. Resolve the active render branch through Core's summary overlay rules.
4. Walk backward to find the last eligible assistant reply.
5. Find `metadata.generation.source_message_id` for that reply, and validate the
   source Message is on the active branch with an allowed user-like role and
   kind.
6. Mark generated suffix Messages from the source child through the retry target
   with `metadata.branch_effect.state = "superseded"` and the command entry id.
7. Collect provider message ids from delivered assistant Messages in that suffix
   when delivery metadata contains them.
8. Set `current_leaf_message_id = source_message_id`.
9. Acquire a generation lease under the same Conversation lock with
   `owner_source_type = "command_retry"`, `owner_source_id = command_entry_id`,
   and the original `source_message_id`.
10. Commit.
11. Best-effort recall previously delivered assistant output before starting the
    replacement generation, when the adapter supports recall.
12. If no provider message was recalled because the channel lacks recall support,
    the old output had no provider message id, or recall failed, return
    control feedback before the replacement generation starts.
13. Start the normal generation runner with `source_message_id`, `lease_id`,
    `owner_source_type = "command_retry"`, and `owner_source_id =
    command_entry_id`.

The new generation writes `metadata.retry_of_message_id` and
`metadata.retry_command_entry_id` on its generated assistant, tool, and error
Messages. It must not copy the original user Message, create a new user turn, or
reuse old provider-private continuation state.

If the old turn already produced external side effects, `retry` does not roll
them back. Retried tool calls still pass through command ACL, AuthZ, and the
owning tool or domain idempotency boundary. Business compensation belongs to the
owning Work, Tool, future Capability, or domain design.

For IM channels that support message recall, the old visible assistant message
should be recalled before the replacement assistant message is sent. Channels
without recall support simply keep the old visible message; the superseded
branch marker still defines what future AIAgent context renders.

### `steer`

`steer` injects a human steering note into the current active generation. It lets
a human adjust direction while the AIAgent is in a tool-use loop. It does not
interrupt the current tool call, does not create a new user turn, and does not
render the steering note as ordinary user dialogue.

Handler behavior:

1. Parse `/steer <prompt>`.
2. If the prompt is blank, return a safe error command response or diagnostic
   with `reason = "missing_prompt"`.
3. Lock the active Conversation.
4. If no generation is active, return a safe no-op command response or
   diagnostic with `reason = "no_active_generation"`.
5. If a generation is active, hand the note to the live generation owner as
   process-local control input for the current `lease_id`.
6. When the running Agentic Loop commits the next tool result, it may append the
   note to exactly one tool result Message.
7. If parallel tool calls finish in one commit batch, append notes to the batch's
   last persisted tool result by original tool-call order.
8. If the generation ends before any tool result or the runtime restarts before
   consumption, the steer command expires without durable replay.

Steering content must be marked as a human steering note. It must not masquerade
as external tool output. Provider rendering may place the note inside the same
tool result Message only so the model sees the new context in the next loop
iteration; durable metadata does not preserve the original slash command.
When a steer note is accepted, the command returns tooltip-like
`control_notice` feedback. The feedback confirms only receipt; it must not echo
the steering prompt.

### `stop`

`stop` stops the current unfinished generation. It is Conversation-local
cancellation, not a TargetSession kill and not a tool side-effect rollback.

Handler behavior:

1. Lock the active Conversation.
2. If no generation is active, return a safe no-op command response or
   diagnostic with `reason = "no_active_generation"`.
3. If a generation is active, set `generation.cancelled_at = now()` and a
   content-free cancellation reason.
4. If a `status = generating` assistant Message exists for the active generation
   and no running owner can complete it, mark it with
   `metadata.branch_effect.state = "interrupted"` or the durable error outcome
   defined by the core streaming recovery design.
5. If that generating assistant Message has already produced a streaming or
   partial provider message id, collect it for best-effort recall.
6. Commit.
7. Best-effort recall the unfinished visible provider message when the adapter
   supports recall.
8. If no provider message was recalled because the channel lacks recall support,
   the unfinished output had no provider message id, or recall failed, return
   control feedback so the caller can still see that generation was stopped.
9. The running Agentic Loop observes lease cancellation at the next check and
   stops before committing more assistant or tool output. Streaming cancellation
   is best effort.

Already-started provider calls may return late and be discarded.
Already-started tool side effects are governed by the tool or future Capability
boundary. `stop` does not call the model, execute new tools, or create a fresh
Conversation.

After `stop`, a user may use `retry` to rerun the stopped turn or send a new
ordinary message to continue the Conversation.

### `undo`

`undo` removes the last user/assistant exchange from active branch rendering. It
is branch hygiene, not physical delete. Raw Messages remain durable evidence.

An exchange is:

- The last source Message on the active branch with
  `role = user, kind = normal` or
  `role = im_ambient, kind = introspection`.
- The assistant, tool, and error Messages after that source whose
  `metadata.generation.source_message_id = source_message_id`.

Summary overlay Messages, maintenance diagnostics, and ambient
`kind = normal` Messages do not independently form undoable exchanges.

`undo` uses the Core-resolved active branch after summary overlay. It does not
look through the selected summary's covered interval to find an older hidden
source Message. If undo rewinds the branch to a point where the selected summary
is no longer compatible, raw history becomes visible again until later
compression writes a compatible summary.

Handler behavior:

1. Lock the active Conversation.
2. If a generation is active, return a safe no-op command response or diagnostic
   with `reason = "active_generation_present"`.
3. Resolve the active render branch through Core's summary overlay rules.
4. Walk backward to the last source Message with an allowed role and kind.
5. If no source exists, return a safe no-op command response or diagnostic with
   `reason = "no_undo_target"`.
6. Mark the source and generated suffix Messages with
   `metadata.branch_effect.state = "undone"` and the command entry id.
7. Collect provider message ids from delivered assistant Messages in that suffix
   when delivery metadata contains them.
8. Set `current_leaf_message_id = source.parent_id`; if the source is root, set
   it to `null`.
9. Commit.
10. Best-effort recall previously delivered assistant output when the adapter
    supports recall.
11. If no provider message was recalled because the channel lacks recall support,
    the output had no provider message id, or recall failed, return control
    feedback so the caller can still see that the branch was rewound.

`undo` does not delete raw Messages, rewrite tool side effects, roll back Work,
Artifact, or domain records, call the model, or execute tools. If the removed
exchange produced an external side effect, compensation belongs to the owning
Tool, future Capability, Work, or domain design.

For IM channels that support recall, `undo` cleans up the assistant-visible part
of the undone exchange. It does not recall the user's own source message and
does not claim external side effects have been undone.

## Recovery And Idempotency

Command handling prioritizes Conversation branch consistency and transcript
safety:

- `new` prevents late output from entering the fresh Conversation.
- `stop` converts stale generating output to the interrupted or error outcome
  defined by the core streaming recovery rules.
- If `retry` crashes after marking the old turn but before starting the new run,
  the `metadata.branch_effect.state = "superseded"` suffix remains evidence and
  a later user action may retry again.
- If provider-visible recall fails, the command still succeeds after the durable
  branch mutation commits; the failure is a transport diagnostic, not a
  Conversation rollback reason.
- If `steer` is not consumed by the live generation before runtime loss or
  generation completion, it expires without durable replay.
- If `undo` crashes after marking Messages but before moving the leaf, recovery
  must not leave a branch that both contains an undone suffix and claims the leaf
  has moved past it.

V1 command response policy is intentionally small. Command handlers that finish
without starting a model generation may send a safe command response or
diagnostic when a usable `reply_channel` exists. `retry` sends no separate
command response when it starts a replacement generation; its generated assistant
output is the visible result. If `retry` becomes a no-op or error, it may return a
safe diagnostic command response. Command responses are not persisted as
Messages. Tooltip-like command acknowledgements use outbound `control_notice`;
they are not ordinary assistant text. Longer-running command progress uses
outbound `progress_notice`, which may be edited in place when the channel
supports it. Descriptive command output owned by the EventBus Command Target,
such as `/command` and `/status`, remains ordinary text.

## Implementation Handoff

### Goal

Implement the AIAgent-owned slash command catalog so `new`, `compress`, `retry`,
`steer`, `stop`, and `undo` work inside Conversation without expanding EventBus,
TargetSession, Channel Adapter, LLMProvider, or Workflow ownership boundaries.

### Context Pointers

- `docs/Architecture.md`
- `docs/design-docs/eventbus/Core.md`
- `docs/design-docs/eventbus/SystemCommands.md`
- `docs/design-docs/AuthZ.md`
- `docs/design-docs/Principal.md`
- `docs/design-docs/ai-agent/Core.md`
- `docs/design-docs/ai-agent/ACL.md`
- `docs/design-docs/ai-agent/ContextCompressionAndCaching.md`

### Constraints

- Do not route AIAgent slash commands through a second EventBus pipeline.
- Do not parse slash text in EventBus.
- Do not let Channel Adapters execute AIAgent slash commands directly.
- Do not let slash commands enter ordinary provider dialogue.
- Do not persist slash command inputs or command responses as Agent durable
  Messages.
- Do not add a turns table or command queue table.
- Do not physically delete raw Messages.
- Do not let `steer` interrupt the current tool call or become a new user turn.
- Do not make `stop` promise cancellation or rollback of an already-started
  external side effect.
- Do not let `retry` or `undo` roll back external side effects or domain
  records.
- Do not add dependencies for this feature without explicit approval.

### Tasks

1. Add the canonical command catalog and alias normalization.
   - Owns: command catalog, default slash tokens, localized aliases, plain-text
     fallback detection, and `bullx.command.invoked` mapping when routed directly
     to `target_type = "ai_agent"`.
   - Acceptance: `/new`, `/新会话`, `/compress`, `/压缩`, `/retry`,
     `/steer <prompt>`, `/stop`, and `/undo` normalize to canonical names;
     provider mention text such as `@Agent retry` may normalize to the same
     canonical command; unknown leading slash tokens do not call the model and
     are not privileged commands.
   - Acceptance: unknown `bullx.command.invoked` names routed to an AIAgent return
     a safe command diagnostic and are not reinterpreted as ordinary user text.
   - Acceptance: adapter-normalized AIAgent commands do not require a generic
     Command Target delegation path.

2. Keep commands out of the durable transcript.
   - Owns: control operation handling, safe command responses, and the invariant
     that command inputs and responses do not write `conversation_messages`.
   - Acceptance: slash commands never add command-specific Message kinds, and
     command responses are never selected for provider input, compression, retry,
     or undo.

3. Connect the command ACL gate.
   - Owns: pre-execution access checks for AIAgent-owned commands.
   - Acceptance: unauthorized callers do not execute command effects; callers
     with Agent `invoke` may execute the current ordinary command catalog; any
     privileged command added later additionally requires `invoke_privileged`.

4. Add runtime generation metadata and generated Message metadata.
   - Owns: `lease_id`, owner source fields, heartbeat/expiration,
     cancellation fields, and `metadata.generation` for
     generated assistant, tool, and error Messages.
   - Acceptance: `retry` and `undo` find source Message and generated suffix
     without a turns table.

5. Implement `new` and `compress`.
   - Owns: Conversation reset, fresh Conversation creation, active-generation
     cancellation, and manual compression handoff.
   - Acceptance: late output from `new` cannot enter the fresh Conversation;
     `compress` does not call the main model, preempt active generation, or
     repeat summary effects.

6. Implement `retry`.
   - Owns: last assistant reply lookup, source derivation, generated suffix
     `metadata.branch_effect.state = "superseded"`, leaf rewind, and retry
     generation metadata.
   - Acceptance: `retry` reruns the last AI reply's source turn without copying
     the user Message, creating a new user turn, or deleting old evidence.
   - Acceptance: when the old assistant output has provider delivery metadata
     and the reply channel supports recall, `retry` recalls the old visible
     output before sending the replacement output.

7. Implement `steer`.
   - Owns: live control input delivery, optional tool result content block
     append, and expired/no-op behavior when no active generation can consume it.
   - Acceptance: `steer` does not interrupt the current tool call; the next tool
     result may receive a clearly marked human steering note when the active
     runtime consumes it.

8. Implement `stop`.
   - Owns: generation lease cancellation, best-effort stream cancellation, and
     stale generating Message recovery.
   - Acceptance: `stop` stops the unfinished turn; late provider or tool output
     no longer advances the active branch; visible partial output has a durable
     interrupted or error outcome.
   - Acceptance: when unfinished streaming output already has a provider message
     id and the reply channel supports recall, `stop` recalls that unfinished
     visible output.

9. Implement `undo`.
   - Owns: last exchange lookup, `metadata.branch_effect.state = "undone"`, leaf
     rewind, and no-delete recovery.
   - Acceptance: `undo` removes the last user/assistant exchange from active
     branch rendering while preserving durable raw Messages.
   - Acceptance: when undone assistant output has provider delivery metadata and
     the reply channel supports recall, `undo` recalls the assistant-visible
     output without recalling the user's source message.

10. Add command transaction and recovery tests.
    - Owns: focused tests for redelivery, active-generation races, crash
      windows, late output, branch leaf consistency, and command response
      exclusion from durable Messages.
    - Acceptance: recovery rules pass without a turns table, command queue
      table, or physical delete path.

### Stop And Ask

Implementation should stop and ask if it would require:

- moving slash command routing semantics into the EventBus matcher;
- making an Adapter read AIAgent Conversation state to decide a command result;
- physically deleting Message evidence for `retry` or `undo`;
- forcing cancellation or rollback of an already-started external side effect;
- making `steer` interrupt the current tool call or enter the model as a new
  user turn;
- allowing a default command to mutate another Conversation, AIAgent,
  Principal, Connected Realm, Work, or domain record;
- adding a turns table, command queue table, delivery table, or independent
  recovery service.

### Done When

- The AIAgent-owned command catalog is centralized in this document.
- Companion Agentic Loop docs reference this document instead of redefining
  slash tokens or command behavior.
- `new`, `compress`, `retry`, `steer`, `stop`, and `undo` have clear canonical
  command, owner, ACL, active-generation, and control semantics.
- Slash commands never enter ordinary provider dialogue.
- Slash command inputs and command responses are not persisted as Agent durable
  Messages.
- `bullx.command.invoked` can drive AIAgent-owned commands directly when routed
  to `target_type = "ai_agent"`.
- `retry` reruns the turn that produced the last AI reply on the active
  Conversation branch and recalls the old visible assistant output when the
  channel supports recall.
- `steer` appends a human steering note to the next tool result after the
  current tool finishes.
- `stop` halts the current unfinished turn and prevents late output from
  advancing the active branch, recalling unfinished visible streaming output
  when the channel supports recall.
- `undo` removes the last user/assistant exchange from active branch rendering
  without deleting durable evidence, and recalls assistant-visible output when
  the channel supports recall.

Verification commands:

```bash
mix format --check-formatted
# focused slash-command normalization, ACL, active-generation race,
# branch recovery, and command-response transcript-exclusion tests
MIX_ENV=test mix compile --warnings-as-errors
bun precommit
```
