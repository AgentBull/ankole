# AIAgent Slash Commands

AIAgent slash commands are Conversation-local control inputs owned by the
AIAgent runtime. They can change the active Conversation, branch position,
generation lease, prompt context, or current Agentic Loop recovery state, but
they are not ordinary user turns and must not enter provider dialogue as normal
user text. EventBus, TargetSession, Channel Adapters, LLMProvider, and Workflow
do not own the business semantics of these commands.

This document defines the current AIAgent-owned command catalog, normalization
rules, command Message contract, active-generation behavior, idempotency, safety
rules, and implementation handoff for `/new`, `/compress`, `/retry`, `/steer`,
`/stop`, and `/undo`.

## Scope

This design covers:

- AIAgent-owned slash command ownership boundaries.
- Slash token, localized alias, and canonical command-name normalization.
- Durable command Message persistence and redelivery idempotency.
- Command metadata, generation coordination metadata, and generated Message
  metadata required for recovery.
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
| `new` | `/new` | `/新会话` | ordinary | Preempt and invalidate the current generation. |
| `compress` | `/compress` | `/压缩` | ordinary | Safe no-op or diagnostic while a generation is active. |
| `retry` | `/retry` | none | ordinary | Safe no-op or diagnostic while a generation is active. |
| `steer` | `/steer <prompt>` | none | ordinary | Attach a steering note to the next tool result; do not interrupt. |
| `stop` | `/stop` | none | ordinary | Preempt and stop the unfinished turn. |
| `undo` | `/undo` | none | ordinary | Safe no-op or diagnostic while a generation is active. |

Default English tokens are always accepted. Localized aliases normalize to the
same canonical command name before authorization, idempotency, execution, or
testing. Default tokens and localized aliases cannot be removed without updating
this design and the focused tests.

System commands such as `/command` and `/status` are Command Target handlers. If
an adapter normalizes one of those inputs to
`type = "bullx.command.invoked"` and an Event Routing Rule routes it to
`target_type = "command"`, the command does not enter an AIAgent model loop.
Channel activation and login commands such as `/preauth` and `/web_auth` are
adapter-owned entry points by default because they may run before Principal
binding and may require provider-private reply context.

A generic Command Target may receive normalized command Events. For commands in
this catalog, the Command Target must delegate through the AIAgent-owned command
service unless another design explicitly assigns ownership elsewhere. It must
not directly edit Conversation internals, write summary Messages, move a
Conversation leaf, or modify generation leases.

## Normalization And Detection

Channel Adapters may normalize provider-native command surfaces into
`type = "bullx.command.invoked"` with command facts under
`data.routing_facts`:

```json
{
  "command_name": "steer",
  "command_args": {"prompt": "focus on the auth module"},
  "command_token": "/steer"
}
```

Adapters are transport-only at this boundary. They may match a provider command
surface, normalize aliases, and pass the accepted CloudEvent to EventBus. They
do not decide whether an AIAgent command is authorized, do not inspect
Conversation state, and do not execute the command.

When an ordinary text Event reaches an AIAgent and its leading text contains an
AIAgent-owned slash token that was not adapter-normalized, the AIAgent runtime
must run the same canonical catalog detection. Detection is deterministic:

- Only a slash token at the beginning of the message is recognized.
- A token-like string in the middle of ordinary text is not a command.
- Text after the token becomes command arguments.
- `/steer` requires a non-empty prompt.
- Alias matching produces a canonical command name before ACL, idempotency,
  routing handoff, or command execution.
- Unknown leading slash tokens are not ordinary user text in v1. The AIAgent
  persists a `role = user, kind = command` Message with canonical name
  `unknown`, terminal outcome `error`, and reason `unknown_command`, then
  returns a fixed safe diagnostic without calling the model or executing tools.
  Unknown slash tokens are never privileged commands.

Only this design or an explicit AIAgent command configuration surface may add
aliases for this catalog.

## Command Message Contract

Every AIAgent-owned command is first persisted as a
`conversation_messages` record:

- `role = user`
- `kind = command`
- `status = complete`
- `content` stores the canonical command name, safe arguments, and a safe
  representation of the original token.
- `target_session_id` and `target_session_entry_id` preserve the side-channel
  source of the triggering Event.
- `metadata.command` stores canonical name, normalized argument digest, token,
  safe requesting Principal evidence, status, outcome, and effects.

Command `content` uses a command-specific block. It must not impersonate
provider dialogue:

```json
[
  {
    "type": "command",
    "name": "steer",
    "token": "/steer",
    "args": {"prompt": "focus on the auth module"}
  }
]
```

`metadata.command` has a stable object shape for redelivery, recovery, and test
assertions:

```json
{
  "command": {
    "name": "steer",
    "token": "/steer",
    "args_digest": "sha256:...",
    "requesting_principal_id": "018f...",
    "status": "pending",
    "outcome": null,
    "effects": {}
  }
}
```

`metadata.command.status` uses only `pending`, `complete`, `noop`, `error`, or
`expired`. `outcome.reason` is a content-free reason code, such as
`no_active_generation`, `active_generation_present`, `no_retry_target`,
`stopped_generation`, `steer_consumed`, `branch_rewound`,
`missing_prompt`, or `generation_finished_without_tool_result`.

`effects` stores only ids and counters, such as `fresh_conversation_id`,
`summary_message_id`, `rewound_to_message_id`, `retry_source_message_id`,
`retry_target_message_id`, `consumed_tool_message_id`,
`pending_steer_sequence`, `stopped_generation_owner_source_id`, and
`affected_message_count`.

A command Message is durable evidence, but it is not rendered as normal provider
dialogue. Whether the command Message becomes the active branch leaf depends on
the command:

- `new` and `compress` may make the command Message the current leaf because
  they do not rerun an earlier user turn.
- `retry`, `stop`, and `undo` keep the command Message on a side branch or audit
  branch, then move `current_leaf_message_id` to the command-defined target.
- `steer` during an active generation keeps the branch leaf unchanged, writes
  the command Message, and records pending generation coordination state.

Redelivery is idempotent. If the same `target_session_entry_id` already produced
a command Message with a terminal command outcome, the command service returns
the recorded outcome without repeating effects or visible confirmations.

## Runtime Metadata

Slash commands reuse the Conversation generation metadata. They do not introduce
a command queue table.

Command-owned generation keys coordinate the active generation and recovery:

```json
{
  "owner_source_type": "target_session_entry",
  "owner_source_id": "018f...",
  "started_at": "2026-05-18T14:35:00Z",
  "expires_at": "2026-05-18T14:45:00Z",
  "heartbeat_at": "2026-05-18T14:36:00Z",
  "invalidated_by_command_id": null,
  "stopped_by_command_id": null,
  "pending_steer_notes": [
    {
      "command_message_id": "018f...",
      "sequence": 1,
      "status": "pending",
      "content": [
        {"type": "human_steering_note", "text": "focus on the auth module"}
      ],
      "consumed_tool_message_id": null
    }
  ]
}
```

`pending_steer_notes` is weak coordination state. The steering text is
Conversation content and may be stored in the command Message and pending note.
Logs, telemetry, command outcome, and diagnostics must not copy that text.

When the running Agentic Loop consumes a pending steer note, it must write the
tool result Message and mark the note `consumed` in the same transaction. This
prevents crash recovery from appending the same steering note twice.

Generated assistant, tool, and error Messages must include content-free
generation metadata so `retry` and `undo` do not require a turns table:

```json
{
  "generation": {
    "source_message_id": "018f-user-or-introspection",
    "source_type": "target_session_entry",
    "source_id": "018f-entry-or-command",
    "root_assistant_message_id": "018f-assistant"
  }
}
```

`source_message_id` points to the user-like Message that triggered this
Agentic Loop. `source_type` is `target_session_entry`, `ambient_batch`, or
`command_retry`. `source_id` is the entry id, batch idempotency key, or retry
command Message id. `root_assistant_message_id` points to the first assistant
Message produced by the generation; later tool, assistant, and error Messages
from the same generation reuse it.

## Transaction Pattern

Every command handler begins with the same transaction pattern:

1. Start an `Ecto.Multi` or database transaction.
2. Lock the active Conversation row for `{agent_principal_id, conversation_key}`.
3. Look up an existing `role = user, kind = command` Message by
   `target_session_entry_id`.
4. If a terminal `metadata.command.status` exists, return the recorded outcome.
5. If missing, append the command Message with
   `metadata.command.status = "pending"`.
6. Re-read `current_leaf_message_id` and `generation` under the same lock.
7. Run the command-specific mutation.
8. Update the command Message `metadata.command.status`, `outcome`, and
   `effects`.
9. Commit before any model call, outbound confirmation, or long-running tool
   work.

Command handlers do not call the model inside the command transaction. If a
command starts or restarts generation, it first commits branch and lease state,
then starts the normal AIAgent generation runner with an explicit source id.

## Authorization And Safety

Every AIAgent-owned command passes through the Agentic Loop command ACL gate
before execution. The current catalog is ordinary access by default because the
commands only change the current AIAgent Conversation branch, generation lease,
or prompt context while preserving durable evidence.

A command requires privileged access or a separate design if it would:

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
safe denial or diagnostic outcome, does not execute command effects, and returns
success to TargetSession progress unless an infrastructure failure prevents safe
completion.

V1 does not define per-command AuthZ actions. The command catalog maps each
command to the same ACL operation tags used elsewhere: the current commands are
`ordinary`; a later privileged command uses the existing AIAgent ACL
`use_privileged` action through `docs/design-docs/ai-agent/ACL.md`. Adding a
separate action such as `command.retry` or `command.stop` requires a design
update because it changes the AuthZ surface.

Telemetry and logs are content-free. They may include command name, outcome,
ids, duration, safe reason code, provider or model ids, and lease state. They
must not include user prompt text, steering text, raw CloudEvents, provider
payloads, credentials, tool result content, private policy data, or reply bearer
handles.

## Active Generation Rules

The generation lease is the active-turn control point. Slash commands have three
active-generation modes:

- **Preemptive:** `new` and `stop` may invalidate the current generation lease.
  The running Agentic Loop must re-check the lease and active Conversation state
  before committing assistant, tool, or error Messages, before starting visible
  output, and before outbound delivery.
- **Deferred in-loop:** `steer` does not invalidate the lease, interrupt the
  current tool call, or create a new user turn. It records a note for the next
  tool result in the same Agentic Loop.
- **Non-preemptive:** `compress`, `retry`, and `undo` do not preempt an active
  generation. While one exists, they write a safe command outcome and end; the
  user may retry after generation finishes or after `/stop`.

If a provider call has already been sent and cannot be cancelled, the AIAgent may
discard the response. If a tool side effect has started, cancellation behavior
belongs to the tool or Capability boundary. The AIAgent runtime owns transcript
safety and idempotency: late results must not become current Conversation truth,
and side effects must not be duplicated by command recovery.

## Command Catalog

### `new`

`new` closes the current active Conversation and creates a fresh active
Conversation for the same `agent_principal_id` and `conversation_key`. It means a
human starts a sibling Conversation, not a child continuation.

Handler behavior:

1. Lock the original active Conversation.
2. Append the command Message as a child of the current leaf.
3. Set the original `current_leaf_message_id` to the command Message id.
4. Set `ended_at = now()` and `metadata.end_reason = "new_session"`.
5. If a generation owner is active and not expired, set
   `generation.invalidated_by_command_id = command_message_id`.
6. Insert one fresh active Conversation with the same `agent_principal_id` and
   `conversation_key`, `current_leaf_message_id = null`, and empty generation
   metadata.
7. Store `effects.fresh_conversation_id`.
8. Mark the command outcome `complete`.
9. Do not call the model or execute tools for the command entry.

Late provider or tool output from the invalidated generation must fail the normal
lease and active-state recheck. It must not write into the fresh Conversation and
must not append ordinary branch output to the ended Conversation.

If the command Event has a usable `reply_channel`, `new` sends a fixed safe
confirmation after commit. The outbound idempotency key includes
`command_message_id`, `fresh_conversation_id`, command outcome, and stable
reply-channel identity.

### `compress`

`compress` manually triggers context compression before the next provider call.
It only changes the future provider-renderable history view. It does not delete
raw Messages, change Brain, Work, audit, or business records, or guarantee that
the next provider call will be under a safe budget.

Handler behavior:

1. Lock the active Conversation and append the command Message as a child of the
   current leaf.
2. If a generation is active, mark the command `noop` with
   `reason = "active_generation_present"`.
3. Otherwise call the manual compression handoff with `conversation_id`,
   `command_message_id`, current raw leaf id, triggering
   `target_session_entry_id`, and safe caller context.
4. Exclude the command Message, current inbound Message, generating Message,
   incomplete tool pair, and command confirmation from compression coverage.
5. If a summary is written, store `effects.summary_message_id`.
6. If no provider-round interval can be compressed, mark the command `noop` with
   `reason = "no_compressible_interval"`.

The command never calls the main model, never executes tools, and never repeats
summary, no-op, or error effects on redelivery.

### `retry`

`retry` retries the turn that produced the last eligible AI reply on the current
Conversation. It is not a new user turn. It sends the original user-like source
Message back through the normal AIAgent generation runner and removes the old
generated suffix from active branch rendering while preserving evidence.

The current design does not add a turns table. The runtime finds the retry
target from the Message tree and content-free generation metadata:

- The retry target is the last eligible assistant reply Message on the active
  branch.
- Eligible assistant replies exclude `kind = summary`, command confirmation,
  maintenance diagnostics, and `status = generating`.
- The turn source is the user-like Message that produced that assistant reply:
  `role = user, kind = normal` or `role = im_ambient, kind = introspection`.
- The turn includes generated assistant, tool, and error Messages after that
  source under the same generation source, through the retry target.

Handler behavior:

1. Lock the active Conversation.
2. Append the command Message on a side branch whose `parent_id` is the current
   leaf. Do not move `current_leaf_message_id` to the command Message.
3. If a generation is active, mark the command `noop` with
   `reason = "active_generation_present"`.
4. Reconstruct the active branch from `current_leaf_message_id`.
5. Walk backward to find the last eligible assistant reply.
6. Find `metadata.generation.source_message_id` for that reply, and validate the
   source Message is on the active branch with an allowed user-like role and
   kind.
7. Mark generated suffix Messages from the source child through the retry target
   with `metadata.superseded_by_command_id = command_message_id`.
8. Set `current_leaf_message_id = source_message_id`.
9. Mark the command `complete` with `effects.retry_target_message_id`,
   `effects.retry_source_message_id`, and `effects.affected_message_count`.
10. Commit.
11. Start the normal generation runner with `source_message_id`,
    `owner_source_type = "command_retry"`, and
    `owner_source_id = command_message_id`.

The new generation writes `metadata.retry_of_message_id` and
`metadata.retry_of_command_id` on its generated assistant, tool, and error
Messages. It must not copy the original user Message, create a new user turn, or
reuse old provider-private continuation state.

If the old turn already produced external side effects, `retry` does not roll
them back. Retried tool calls still pass through Capability idempotency, command
ACL, AuthZ, and side-effect boundaries. Business compensation belongs to the
owning Work, Tool, Capability, or domain design.

### `steer`

`steer` injects a human steering note into the current active generation. It lets
a human adjust direction while the AIAgent is in a tool-use loop. It does not
interrupt the current tool call, does not create a new user turn, and does not
render the steering note as ordinary user dialogue.

Handler behavior:

1. Parse `/steer <prompt>`.
2. If the prompt is blank, mark the command `error` with
   `reason = "missing_prompt"`.
3. Lock the active Conversation and append the command Message on a side branch.
   Do not move `current_leaf_message_id`.
4. If no generation is active, mark the command `noop` with
   `reason = "no_active_generation"`.
5. If a generation is active, append one pending steer note with the next integer
   `sequence`, `command_message_id`, `status = "pending"`, and content block
   `{"type": "human_steering_note", "text": prompt}`.
6. Mark the command `complete` with `effects.pending_steer_sequence`.
7. Commit.
8. When the running Agentic Loop commits the next tool result, lock the
   Conversation, select pending notes ordered by `sequence`, append their content
   blocks to exactly one tool result Message, and update each note to
   `status = "consumed"` with `consumed_tool_message_id`.
9. If parallel tool calls finish in one commit batch, append notes to the batch's
   last persisted tool result by original tool-call order.
10. If the generation ends before any tool result, mark remaining pending notes
    `expired` and update the command outcome reason to
    `generation_finished_without_tool_result` when practical.

Steering content must be marked as a human steering note. It must not masquerade
as external tool output. Provider rendering may place the note inside the same
tool result Message only so the model sees the new context in the next loop
iteration; durable metadata still preserves the command and note source.

### `stop`

`stop` stops the current unfinished generation. It is Conversation-local
cancellation, not a TargetSession kill and not a tool side-effect rollback.

Handler behavior:

1. Lock the active Conversation.
2. Append the command Message on a side branch. Do not move
   `current_leaf_message_id`.
3. If no generation is active, mark the command `noop` with
   `reason = "no_active_generation"`.
4. If a generation is active, set `generation.invalidated_by_command_id` and
   `generation.stopped_by_command_id` to the command Message id.
5. If a `status = generating` assistant Message exists for the active generation
   and no running owner can complete it, mark it with the interrupted or error
   recovery marker defined by the core streaming recovery design.
6. Mark the command `complete` with
   `effects.stopped_generation_owner_source_id`.
7. Commit.
8. The running Agentic Loop observes lease invalidation at the next check and
   stops before committing more assistant or tool output. Streaming cancellation
   is best effort.

Already-started provider calls may return late and be discarded.
Already-started tool side effects are governed by the tool or Capability
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

Command Messages, summary overlay Messages, maintenance diagnostics, and ambient
`kind = normal` Messages do not independently form undoable exchanges.

Handler behavior:

1. Lock the active Conversation.
2. Append the command Message on a side branch. Do not move
   `current_leaf_message_id`.
3. If a generation is active, mark the command `noop` with
   `reason = "active_generation_present"`.
4. Reconstruct the active branch from `current_leaf_message_id`.
5. Walk backward to the last source Message with an allowed role and kind.
6. If no source exists, mark the command `noop` with
   `reason = "no_undo_target"`.
7. Mark the source and generated suffix Messages with
   `metadata.undone_by_command_id = command_message_id`.
8. Set `current_leaf_message_id = source.parent_id`; if the source is root, set
   it to `null`.
9. Mark the command `complete` with `effects.undo_source_message_id`,
   `effects.rewound_to_message_id`, and `effects.affected_message_count`.
10. Commit.

`undo` does not delete raw Messages, rewrite tool side effects, roll back Work,
Artifact, or domain records, call the model, or execute tools. If the removed
exchange produced an external side effect, compensation belongs to the owning
Tool, Capability, Work, or domain design.

## Recovery And Idempotency

Command recovery prioritizes Conversation branch consistency and transcript
safety:

- Redelivery of a command with terminal outcome returns the recorded outcome.
- `new` prevents late output from entering the fresh Conversation.
- `stop` converts stale generating output to the interrupted or error outcome
  defined by the core streaming recovery rules.
- If `retry` crashes after marking the old turn but before starting the new run,
  recovery preserves the superseded suffix and can restart from the turn source.
- If `steer` crashes after writing the pending note but before tool result
  commit, the recovered loop consumes the note once. If the generation already
  ended, recovery marks the note expired or no-op.
- If `undo` crashes after marking Messages but before moving the leaf, redelivery
  completes the leaf move. Recovery must not leave a branch that both contains an
  undone suffix and claims the leaf has moved past it.

V1 command confirmation policy is fixed. Command handlers that finish without
starting a model generation send a fixed safe confirmation or diagnostic when a
usable `reply_channel` exists. `retry` sends no separate confirmation when it
starts a replacement generation; its generated assistant output is the visible
result. If `retry` becomes a no-op or error, it follows the fixed diagnostic
path. Every confirmation uses an outbound idempotency key derived from command
Message id, command outcome, and stable reply-channel identity.

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
     fallback detection, adapter-normalized command Event mapping.
   - Acceptance: `/new`, `/新会话`, `/compress`, `/压缩`, `/retry`,
     `/steer <prompt>`, `/stop`, and `/undo` normalize to canonical names;
     unknown leading slash tokens persist an `unknown` command error outcome,
     do not call the model, and are not privileged commands.

2. Add command Message persistence and idempotency.
   - Owns: `role = user, kind = command` writes, command content block,
     `metadata.command` shape, redelivery detection, and fixed confirmation
     idempotency.
   - Acceptance: the same command entry redelivery does not repeat command
     effects, outcome writes, or visible confirmation.

3. Connect the command ACL gate.
   - Owns: pre-execution access checks for AIAgent-owned commands.
   - Acceptance: unauthorized callers do not execute command effects; ordinary
     callers may execute the current ordinary command catalog; any privileged
     command added later rejects ordinary callers.

4. Add runtime generation metadata and generated Message metadata.
   - Owns: `invalidated_by_command_id`, `stopped_by_command_id`,
     `pending_steer_notes`, and `metadata.generation` for generated assistant,
     tool, and error Messages.
   - Acceptance: `retry` and `undo` find source Message and generated suffix
     without a turns table; `steer` pending notes are consumed once after crash
     recovery.

5. Implement `new` and `compress`.
   - Owns: Conversation reset, fresh Conversation creation, active-generation
     invalidation, and manual compression handoff.
   - Acceptance: late output from `new` cannot enter the fresh Conversation;
     `compress` does not call the main model, preempt active generation, or
     repeat summary effects.

6. Implement `retry`.
   - Owns: last assistant reply lookup, source derivation, generated suffix
     supersede marker, leaf rewind, and retry generation metadata.
   - Acceptance: `retry` reruns the last AI reply's source turn without copying
     the user Message, creating a new user turn, or deleting old evidence.

7. Implement `steer`.
   - Owns: pending note creation, single-use consumption, tool result content
     block append, and expired/no-op outcome.
   - Acceptance: `steer` does not interrupt the current tool call; the next tool
     result receives a clearly marked human steering note exactly once.

8. Implement `stop`.
   - Owns: generation lease invalidation, best-effort stream cancellation, and
     stale generating Message recovery.
   - Acceptance: `stop` stops the unfinished turn; late provider or tool output
     no longer advances the active branch; visible partial output has a durable
     interrupted or error outcome.

9. Implement `undo`.
   - Owns: last exchange lookup, undone marker, leaf rewind, and no-delete
     recovery.
   - Acceptance: `undo` removes the last user/assistant exchange from active
     branch rendering while preserving durable raw Messages.

10. Add command transaction and recovery tests.
    - Owns: focused tests for redelivery, active-generation races, crash
      windows, late output, branch leaf consistency, metadata shape, and fixed
      confirmation idempotency.
    - Acceptance: recovery and idempotency rules pass without a turns table,
      command queue table, or physical delete path.

### Stop And Ask

Implementation should stop and ask if it would require:

- moving slash command routing semantics into the EventBus matcher;
- making an Adapter read AIAgent Conversation state to decide a command outcome;
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
  command, owner, ACL, active-generation, and idempotency semantics.
- Slash commands never enter ordinary provider dialogue.
- `retry` reruns the turn that produced the last AI reply on the active
  Conversation branch.
- `steer` appends a human steering note to the next tool result after the
  current tool finishes.
- `stop` halts the current unfinished turn and prevents late output from
  advancing the active branch.
- `undo` removes the last user/assistant exchange from active branch rendering
  without deleting durable evidence.

Verification commands:

```bash
mix format --check-formatted
# focused slash-command normalization, ACL, command-message idempotency,
# active-generation race, branch recovery, and confirmation idempotency tests
MIX_ENV=test mix compile --warnings-as-errors
bun precommit
```
