import { and, eq, ne } from 'drizzle-orm'
import { DB } from '@/common/database'
import { toJsonArray, toJsonObject, toJsonValue } from '@/common/json'
import { ExternalGatewayAgentEvents, type JsonObject, type JsonValue } from '@/common/db-schema'
import { logger as defaultLogger, type Logger } from '@/common/logger'
import { normalizeInboundText } from '@/common/normalize'
import { recordAgentRoomObservation } from '@/chat-recall/projection'
import { isPlainObject } from '@pleisto/active-support'
import type { AgentResult } from '@/principals/agents/service'
import { materializeInboundMessageAttachments, type ExternalMediaComputerWriter } from './media-cache'
import type {
  ExternalGatewayAgentEnvelope,
  ExternalGatewayAgentEventKey,
  ExternalGatewayCanonicalType,
  DrizzleExternalGatewayAgentEventQueue,
  ExternalGatewaySlashCommandStub
} from './agent-events'
import { externalGatewayBatchKey, externalGatewaySessionId } from './agent-events'
import type { AgentExternalBinding, GroupMessageMode } from './metadata'
import type { ExternalGatewayProjectionSink } from './core/projection'
import type {
  ExternalGatewayActionEvent,
  ExternalGatewayAdapter,
  ExternalGatewayAdapterContext,
  ExternalGatewayAdapterLogger,
  ExternalGatewayMessageDeletedEvent,
  ExternalGatewayMessageInput,
  ExternalGatewayReactionEvent,
  ExternalGatewayRoomInput,
  ExternalGatewayWebhookOptions
} from './core/events'

/**
 * A configured binding after the runtime has resolved its group-message mode.
 *
 * `groupMessageMode` is optional on the parsed metadata binding but always
 * present here: startup fills it from metadata, then app-config, then the
 * default, so the handlers below never have to re-derive it.
 */
export interface RuntimeExternalBinding extends AgentExternalBinding {
  groupMessageMode: GroupMessageMode
}

/**
 * Everything one agent binding needs to turn normalized provider events into
 * input-window rows and projection writes. The runtime builds one of these per
 * (agent, channel) and hands it to the adapter as its context.
 */
export interface CreateExternalGatewayAdapterContextInput {
  adapter: ExternalGatewayAdapter
  agent: AgentResult
  binding: RuntimeExternalBinding
  eventQueue: DrizzleExternalGatewayAgentEventQueue
  logger?: Logger
  projection: ExternalGatewayProjectionSink
  getComputerFileWriter?(agentUid: string, signal?: AbortSignal): Promise<ExternalMediaComputerWriter>
  getInFlightAgentEvents?(): readonly ExternalGatewayAgentEventKey[]
  scheduleDrain(availableAt?: Date): void
  /** Reads the executor's pending-clarify gate so group replies can be routed in. */
  roomHasPendingClarify?(providerRoomId: string): boolean
}

/**
 * Builds the adapter-facing context for one binding.
 *
 * The four `emit*` methods are the only ingress door: an adapter normalizes a
 * provider event and calls one of them, and the matching handler below does the
 * dedup, identity mapping, projection, and enqueue. `runWithWebhookOptions`
 * wraps each call so an adapter can opt the work into background execution and
 * return its webhook ack immediately.
 */
export function createExternalGatewayAdapterContext(
  input: CreateExternalGatewayAdapterContextInput
): ExternalGatewayAdapterContext {
  const logger =
    input.logger?.child?.({ component: 'external-gateway', bindingName: input.binding.name }) ??
    defaultLogger.child({ component: 'external-gateway', bindingName: input.binding.name })
  const runtime = { ...input, logger }

  return {
    emitAction: (event, options) => runWithWebhookOptions(handleAction(runtime, event), options),
    emitMessage: (message, options) => runWithWebhookOptions(handleInboundReceive(runtime, message), options),
    emitMessageDeleted: (event, options) => runWithWebhookOptions(handleMessageDeleted(runtime, event), options),
    emitReaction: (event, options) => runWithWebhookOptions(handleReaction(runtime, event), options),
    getLogger: prefix => adapterLogger(logger, prefix),
    getUserName: () => input.adapter.userName
  }
}

/**
 * Adapts a plugin's loose console-style logging onto the structured host logger.
 *
 * Plugins are third-party code and call `info(msg)`, `info(obj, msg)`, or
 * `info(err)` in whatever shape they like. The host logger wants
 * `(data, message)`, so every call is funneled through `pluginLogEntry` to
 * recover a sensible split. debug/warn are optional on the host logger and
 * fall through silently when absent.
 */
function adapterLogger(logger: Logger, prefix?: string): ExternalGatewayAdapterLogger {
  const scoped = prefix ? (logger.child?.({ pluginLogger: prefix }) ?? logger) : logger
  return {
    debug: (...args) => {
      const entry = pluginLogEntry(args)
      scoped.debug?.(entry.data, entry.message)
    },
    error: (...args) => {
      const entry = pluginLogEntry(args)
      scoped.error(entry.data, entry.message)
    },
    info: (...args) => {
      const entry = pluginLogEntry(args)
      scoped.info(entry.data, entry.message)
    },
    warn: (...args) => {
      const entry = pluginLogEntry(args)
      scoped.warn?.(entry.data, entry.message)
    }
  }
}

/**
 * Recovers a `(data, message)` pair from a plugin's variadic log arguments.
 *
 * Handles the three shapes plugins actually use: a leading message string, a
 * leading data object followed by a message, or neither. A message string that
 * already contains "[object Object]" means the plugin string-concatenated an
 * object into its template; that mangled text is kept as `rawMessage` so the
 * lost object is at least visible, and a generic message is substituted.
 */
function pluginLogEntry(args: readonly unknown[]): { data: Record<string, unknown>; message: string } {
  if (typeof args[0] === 'string') {
    if (args[0].includes('[object Object]')) {
      return {
        data: {
          rawMessage: args[0],
          ...pluginLogData(args.slice(1))
        },
        message: 'External Gateway adapter log'
      }
    }
    return {
      data: pluginLogData(args.slice(1)),
      message: args[0]
    }
  }

  if (isPlainObject(args[0]) && typeof args[1] === 'string') {
    return {
      data: args[0],
      message: args[1]
    }
  }

  return {
    data: pluginLogData(args),
    message: 'External Gateway adapter log'
  }
}

function pluginLogData(args: readonly unknown[]): Record<string, unknown> {
  if (args.length === 0) return {}
  if (args.length === 1 && args[0] instanceof Error) return { err: serializeLogError(args[0]) }
  if (args.length === 1 && isPlainObject(args[0])) return args[0]
  return { args: args.map(arg => (arg instanceof Error ? serializeLogError(arg) : arg)) }
}

/**
 * Error fields are non-enumerable, so a raw Error inside an args array
 * serializes as `{"name": "..."}` with the message and stack silently dropped —
 * exactly the failure mode that made the Lark card-update error storms
 * undiagnosable in production. Flatten them explicitly.
 */
function serializeLogError(error: Error): Record<string, unknown> {
  return {
    name: error.name,
    message: error.message,
    stack: error.stack,
    ...(error.cause instanceof Error ? { cause: { name: error.cause.name, message: error.cause.message } } : {})
  }
}

/**
 * Turns one inbound provider message into a projection write and (when it is
 * addressed to the agent) an input-window row.
 *
 * The order matters and is load-bearing: normalize text, decide delivery,
 * drop tombstoned/ignored messages, materialize attachments, project to the
 * durable mirror, then enqueue. Everything that is merely observed stops after
 * projection so chat history stays complete without waking the agent. The
 * tombstone is re-checked after the slow attachment/projection step because a
 * recall can land in that window (see the inline note before the second check).
 */
async function handleInboundReceive(
  runtime: CreateExternalGatewayAdapterContextInput,
  message: ExternalGatewayMessageInput
): Promise<void> {
  // Normalize once at the inbound chokepoint so the projection mirror, the agent
  // envelope (→ conversation → model), slash-command parsing, and the clarify gate
  // all observe the same canonical text (full-width space/digits → ASCII).
  if (message.text) message = { ...message, text: normalizeInboundText(message.text) }
  const room = await roomForMessage(runtime.adapter, message)
  let delivery = deliveryForMessage(runtime.binding.groupMessageMode, room, message)
  // pending-clarify gate: a group reply (even non-@mention) must reach the
  // conversation as the answer that starts the next turn, so upgrade it to
  // addressed while this room is awaiting one. The registry is single-shot —
  // the first answer wins and closes the gate; slash commands are still
  // detected below and take precedence.
  if (delivery !== 'addressed' && Boolean(message.text?.trim()) && runtime.roomHasPendingClarify?.(room.id) === true) {
    delivery = 'addressed'
  }
  // Per-agent routing attribution: with several agents sharing one room, this
  // line answers "which agent claimed this message, as what, and why" without
  // reading the database. Pure observation stays at debug (the bulk of group
  // traffic); anything an agent will act on logs at info.
  const decisionLog = {
    agentUid: runtime.agent.agent.uid,
    bindingName: runtime.binding.name,
    adapter: runtime.binding.adapter,
    groupMessageMode: runtime.binding.groupMessageMode,
    providerMessageId: message.id,
    providerRoomId: room.id,
    providerThreadId: message.threadId,
    roomIsDM: room.isDM,
    delivery,
    isMention: message.isMention === true,
    authorUserId: message.author.userId,
    authorIsBot: message.author.isBot,
    authorIsMe: message.author.isMe,
    attachmentCount: message.attachments?.length ?? 0,
    textPreview: message.text ? Array.from(message.text).slice(0, 120).join('') : ''
  }
  if (delivery === 'observed' || delivery === 'ignored') {
    runtime.logger?.debug?.(decisionLog, 'External Gateway inbound message delivery decision')
  } else {
    runtime.logger?.info?.(decisionLog, 'External Gateway inbound message delivery decision')
  }
  if (delivery === 'ignored') return
  const tombstoned = await runtime.eventQueue.hasInputTombstone({
    agentUid: runtime.agent.agent.uid,
    bindingName: runtime.binding.name,
    providerMessageId: message.id,
    providerRoomId: room.id
  })
  if (tombstoned) return

  message = await materializeInboundMessageAttachments(message, {
    agentUid: runtime.agent.agent.uid,
    binding: runtime.binding,
    computerWriter: runtime.getComputerFileWriter
      ? () => runtime.getComputerFileWriter!(runtime.agent.agent.uid)
      : undefined,
    logger: runtime.logger,
    room
  })

  await runtime.projection.projectMessage({
    room,
    message
  })
  await recordAgentRoomObservation({
    agentUid: runtime.agent.agent.uid,
    bindingName: runtime.binding.name,
    roomId: room.id,
    metadata: {
      delivery,
      adapter: runtime.binding.adapter
    }
  })
  if (delivery === 'observed') return

  // Re-check the recall/delete tombstone before enqueuing. The check above ran
  // before the (potentially slow) attachment materialization and projection, and
  // a recall is a light handler that can land and complete during that window —
  // its pending-receive neutralization finds nothing because this receive is not
  // enqueued yet. Without this second check a just-recalled message would still be
  // delivered to the agent with no compensating recall event. The message stays
  // projected above so the recall handler can still mark it recalled in chat history.
  const recalledDuringMaterialize = await runtime.eventQueue.hasInputTombstone({
    agentUid: runtime.agent.agent.uid,
    bindingName: runtime.binding.name,
    providerMessageId: message.id,
    providerRoomId: room.id
  })
  if (recalledDuringMaterialize) return

  const command = commandFromMessage(message)
  const providerRoomId = room.id
  const providerThreadId = message.threadId
  const envelope = envelopeForMessage({
    agentUid: runtime.agent.agent.uid,
    binding: runtime.binding,
    command,
    message,
    room,
    type: command ? 'slash_command' : 'message.received'
  })

  // Three enqueue paths by delivery kind. Slash commands and ambient messages
  // each become their own event (no batching) because they are not the "user is
  // typing several messages at the agent" case. Only an addressed receive goes
  // through `enqueueReceive`, which opens/extends the short batch window so a
  // burst of replies coalesces into one agent turn keyed by room+thread.
  const event =
    command !== undefined
      ? await runtime.eventQueue.enqueueInboundMessage({
          agentUid: runtime.agent.agent.uid,
          actorKey: actorKeyFromMessage(message),
          bindingName: runtime.binding.name,
          deliveryMode: 'command',
          payload: envelope,
          providerEventId: envelope.id,
          providerMessageId: message.id,
          providerRoomId,
          providerThreadId,
          type: 'slash_command'
        })
      : delivery === 'ambient'
        ? await runtime.eventQueue.enqueueInboundMessage({
            agentUid: runtime.agent.agent.uid,
            actorKey: actorKeyFromMessage(message),
            bindingName: runtime.binding.name,
            deliveryMode: 'ambient',
            payload: envelope,
            providerEventId: envelope.id,
            providerMessageId: message.id,
            providerRoomId,
            providerThreadId,
            type: 'message.received'
          })
        : await runtime.eventQueue.enqueueReceive({
            agentUid: runtime.agent.agent.uid,
            actorKey: actorKeyFromMessage(message),
            batchKey: externalGatewayBatchKey({
              agentUid: runtime.agent.agent.uid,
              bindingName: runtime.binding.name,
              providerRoomId,
              providerThreadId
            }),
            bindingName: runtime.binding.name,
            deliveryMode: 'addressed',
            payload: envelope,
            providerEventId: envelope.id,
            providerMessageId: message.id,
            providerRoomId,
            providerThreadId
          })

  if (!event) return
  runtime.scheduleDrain(event.availableAt)
}

/**
 * Handles a provider delete/recall and reconciles it against the matching
 * receive, which may be in any of three states.
 *
 * Always: record a tombstone (so a receive that has not arrived yet is dropped)
 * and hard-delete the projected message. Then, depending on the receive:
 *  - still pending inside the batch window → remove it; the agent never saw it,
 *    so emitting a separate recall event would be noise. Done.
 *  - in-flight or already materialized into a delivered turn → the agent has
 *    (or is about to) see the message, so a recall/delete event is enqueued to
 *    compensate it.
 *  - absent and not in-flight → nothing to reconcile. Done.
 *
 * The pending removal is fenced by `inFlightEvents`: a receive currently being
 * delivered must not be deleted out from under the executor, so that case
 * reports `in_flight` and falls through to the compensating enqueue instead.
 */
async function handleMessageDeleted(
  runtime: CreateExternalGatewayAdapterContextInput,
  event: ExternalGatewayMessageDeletedEvent
): Promise<void> {
  const room = await roomForLifecycle(runtime.adapter, event)
  await recordAgentRoomObservation({
    agentUid: runtime.agent.agent.uid,
    bindingName: runtime.binding.name,
    roomId: room.id,
    metadata: {
      delivery: 'lifecycle',
      adapter: runtime.binding.adapter
    }
  })
  const type = event.kind === 'recalled' ? 'message.recalled' : 'message.deleted'
  const envelope = envelopeForDelete({
    agentUid: runtime.agent.agent.uid,
    binding: runtime.binding,
    event,
    room,
    type
  })

  runtime.logger?.debug?.(
    {
      agentUid: runtime.agent.agent.uid,
      type,
      messageId: event.messageId,
      threadId: event.threadId,
      roomId: room.id,
      raw: event.raw
    },
    'External Gateway message lifecycle event accepted'
  )

  await runtime.eventQueue.recordInputTombstone({
    agentUid: runtime.agent.agent.uid,
    bindingName: runtime.binding.name,
    providerMessageId: event.messageId,
    providerRoomId: room.id
  })

  runtime.logger?.debug?.(
    {
      agentUid: runtime.agent.agent.uid,
      type,
      messageId: event.messageId,
      roomId: room.id
    },
    'External Gateway message lifecycle tombstone recorded'
  )

  const projectedDeleted = await runtime.projection.projectDelete({ room, messageId: event.messageId })
  runtime.logger?.debug?.(
    {
      agentUid: runtime.agent.agent.uid,
      type,
      messageId: event.messageId,
      roomId: room.id,
      projectedDeleted
    },
    'External Gateway message lifecycle projection delete completed'
  )

  const pending = await runtime.eventQueue.mutatePendingReceive({
    agentUid: runtime.agent.agent.uid,
    bindingName: runtime.binding.name,
    inFlightEvents: runtime.getInFlightAgentEvents?.(),
    providerMessageId: event.messageId,
    providerRoomId: room.id,
    remove: true
  })
  runtime.logger?.debug?.(
    {
      agentUid: runtime.agent.agent.uid,
      type,
      messageId: event.messageId,
      roomId: room.id,
      pending
    },
    'External Gateway message lifecycle pending input mutation completed'
  )
  if (pending === 'removed') return

  const delivered = await hasDeliveredReceive(runtime.agent.agent.uid, runtime.binding.name, room.id, event.messageId)
  const receiveState =
    pending === 'in_flight' ? 'in_flight' : delivered ? 'materialized' : pending === 'not_pending' ? 'absent' : pending
  runtime.logger?.debug?.(
    {
      agentUid: runtime.agent.agent.uid,
      type,
      messageId: event.messageId,
      roomId: room.id,
      delivered,
      receiveState
    },
    'External Gateway message lifecycle delivered receive lookup completed'
  )
  if (!delivered && pending !== 'in_flight') return

  const queued = await runtime.eventQueue.enqueue({
    agentUid: runtime.agent.agent.uid,
    bindingName: runtime.binding.name,
    deliveryMode: 'lifecycle',
    payload: envelope,
    providerEventId: envelope.id,
    providerMessageId: event.messageId,
    providerRoomId: room.id,
    providerThreadId: event.threadId,
    type
  })
  runtime.logger?.debug?.(
    {
      agentUid: runtime.agent.agent.uid,
      type,
      messageId: event.messageId,
      roomId: room.id,
      queuedEventId: queued.providerEventId
    },
    'External Gateway message lifecycle event enqueued for delivered receive'
  )
  runtime.scheduleDrain(queued.availableAt)
}

/**
 * Records a reaction into the projection mirror only.
 *
 * Reactions are observation, not addressed input, so this never enqueues an
 * agent event — it just keeps the durable message mirror's reaction map current
 * for later recall/memory.
 */
async function handleReaction(
  runtime: CreateExternalGatewayAdapterContextInput,
  event: ExternalGatewayReactionEvent
): Promise<void> {
  const room = event.room?.id ? event.room : await roomForThread(runtime.adapter, event.threadId, event.room)
  if (!room.id) throw new Error('External Gateway reaction event missing room id')
  await recordAgentRoomObservation({
    agentUid: runtime.agent.agent.uid,
    bindingName: runtime.binding.name,
    roomId: room.id,
    metadata: {
      delivery: 'reaction',
      adapter: runtime.binding.adapter
    }
  })
  await runtime.projection.projectReaction({
    ...event,
    room
  })
}

/**
 * Turns an interactive action (a card button press) into an agent event.
 *
 * Unlike a reaction, an action is an explicit user request to the agent, so it
 * is always enqueued. `actorKey` is the pressing user, which lets the executor
 * attribute the action even when no message id is present (some actions carry
 * only an `actionId`).
 */
async function handleAction(
  runtime: CreateExternalGatewayAdapterContextInput,
  event: ExternalGatewayActionEvent
): Promise<void> {
  const room = await roomForThread(runtime.adapter, event.threadId, event.room)
  await recordAgentRoomObservation({
    agentUid: runtime.agent.agent.uid,
    bindingName: runtime.binding.name,
    roomId: room.id,
    metadata: {
      delivery: 'action',
      adapter: runtime.binding.adapter
    }
  })
  const envelope = envelopeForAction({
    agentUid: runtime.agent.agent.uid,
    binding: runtime.binding,
    event,
    room
  })
  const queued = await runtime.eventQueue.enqueue({
    agentUid: runtime.agent.agent.uid,
    actorKey: event.user.userId,
    bindingName: runtime.binding.name,
    deliveryMode: 'action',
    payload: envelope,
    providerEventId: envelope.id,
    providerMessageId: event.messageId ?? null,
    providerRoomId: room.id,
    providerThreadId: event.threadId,
    type: 'action'
  })
  runtime.scheduleDrain(queued.availableAt)
}

/**
 * Decides how a message relates to the agent, the first routing gate for every
 * inbound message.
 *
 * A DM or an @mention is always `addressed` — the user is talking to the agent.
 * Otherwise the room's group mode decides: `addressed_only` ignores it (no
 * projection, no turn), `observe_all` keeps it as `observed` (projected for
 * history only), and the remaining mode treats it as `ambient` (enqueued as
 * background context, but not a direct request). The pending-clarify gate in
 * the caller can still upgrade an otherwise non-addressed message.
 *
 * @returns `addressed` wakes the agent; `ambient` enqueues as context;
 *   `observed` only projects to history; `ignored` drops the message entirely.
 */
export function deliveryForMessage(
  groupMessageMode: GroupMessageMode,
  room: Pick<ExternalGatewayRoomInput, 'isDM'>,
  message: Pick<ExternalGatewayMessageInput, 'isMention'>
): 'addressed' | 'ambient' | 'ignored' | 'observed' {
  if (room.isDM) return 'addressed'
  if (message.isMention === true) return 'addressed'

  if (groupMessageMode === 'addressed_only') return 'ignored'
  if (groupMessageMode === 'observe_all') return 'observed'
  return 'ambient'
}

/**
 * Builds the CloudEvents-shaped envelope the executor consumes for a received
 * message or slash command.
 *
 * `id` is the provider event id, which doubles as the enqueue idempotency key,
 * so the same provider message can be redelivered without producing a second
 * input row. `session.id` binds the envelope to the agent's per-room
 * conversation so replies thread into the right context.
 */
function envelopeForMessage(input: {
  agentUid: string
  binding: RuntimeExternalBinding
  command?: ExternalGatewaySlashCommandStub
  message: ExternalGatewayMessageInput
  room: Required<Pick<ExternalGatewayRoomInput, 'id'>> & ExternalGatewayRoomInput
  type: Extract<ExternalGatewayCanonicalType, 'message.received' | 'slash_command'>
}): ExternalGatewayAgentEnvelope {
  const id = providerEventId(input.type, input.room.id, input.message.id, input.command?.name)
  const mentions = toJsonArray(input.message.mentions ?? mentionsFromMessage(input.message))
  const data: JsonObject = {
    room: roomJson(input.room),
    message: messageJson(input.message, mentions),
    mentions,
    raw: toJsonValue(input.message.raw),
    session: {
      id: externalGatewaySessionId(input.agentUid, input.room.id),
      scope: 'external_room'
    }
  }
  if (input.command) data.command = toJsonObject(input.command)

  return {
    specversion: '1.0',
    id,
    source: `external://${input.binding.adapter}/${encodeURIComponent(input.room.id)}`,
    type: input.type,
    subject: `external_messages:${input.message.id}`,
    time: new Date().toISOString(),
    data: data as unknown as ExternalGatewayAgentEnvelope['data']
  }
}

/**
 * Builds the envelope for a delete/recall lifecycle event.
 *
 * The id mixes in a `revision` (the delete timestamp or provider event id) so a
 * delete and a later recall of the same message do not collide on the
 * idempotency key and silently dedup to one event.
 */
function envelopeForDelete(input: {
  agentUid: string
  binding: RuntimeExternalBinding
  event: ExternalGatewayMessageDeletedEvent
  room: Required<Pick<ExternalGatewayRoomInput, 'id'>> & ExternalGatewayRoomInput
  type: Extract<ExternalGatewayCanonicalType, 'message.deleted' | 'message.recalled'>
}): ExternalGatewayAgentEnvelope {
  const revision = deletionRevision(input.event)
  return {
    specversion: '1.0',
    id: providerEventId(input.type, input.room.id, input.event.messageId, revision),
    source: `external://${input.binding.adapter}/${encodeURIComponent(input.room.id)}`,
    type: input.type,
    subject: `external_messages:${input.event.messageId}`,
    time: new Date().toISOString(),
    data: {
      room: roomJson(input.room),
      message: {
        id: input.event.messageId,
        threadId: input.event.threadId
      },
      mentions: [],
      raw: toJsonValue(input.event.raw),
      session: {
        id: externalGatewaySessionId(input.agentUid, input.room.id),
        scope: 'external_room'
      }
    }
  }
}

/**
 * Builds the envelope for an interactive action.
 *
 * `subject` points at the message the button lives on when there is one, and
 * otherwise at the action itself, so a free-standing action (no host message)
 * is still addressable. The action's id, value, and user are carried in `data`.
 */
function envelopeForAction(input: {
  agentUid: string
  binding: RuntimeExternalBinding
  event: ExternalGatewayActionEvent
  room: Required<Pick<ExternalGatewayRoomInput, 'id'>> & ExternalGatewayRoomInput
}): ExternalGatewayAgentEnvelope {
  const id = providerEventId(
    'action',
    input.room.id,
    input.event.messageId ?? input.event.actionId,
    input.event.actionId
  )

  return {
    specversion: '1.0',
    id,
    source: `external://${input.binding.adapter}/${encodeURIComponent(input.room.id)}`,
    type: 'action',
    subject: input.event.messageId
      ? `external_messages:${input.event.messageId}`
      : `external_actions:${input.event.actionId}`,
    time: new Date().toISOString(),
    data: {
      room: roomJson(input.room),
      message: input.event.messageId
        ? {
            id: input.event.messageId,
            threadId: input.event.threadId
          }
        : {},
      mentions: [],
      raw: toJsonValue(input.event.raw),
      session: {
        id: externalGatewaySessionId(input.agentUid, input.room.id),
        scope: 'external_room'
      },
      action: {
        id: input.event.actionId,
        value: input.event.value ?? null,
        user: toJsonObject(input.event.user)
      }
    } as ExternalGatewayAgentEnvelope['data']
  }
}

async function roomForMessage(
  adapter: ExternalGatewayAdapter,
  message: ExternalGatewayMessageInput
): Promise<Required<Pick<ExternalGatewayRoomInput, 'id'>> & ExternalGatewayRoomInput> {
  return roomForThread(adapter, message.threadId, message.room)
}

async function roomForLifecycle(
  adapter: ExternalGatewayAdapter,
  event: ExternalGatewayMessageDeletedEvent
): Promise<Required<Pick<ExternalGatewayRoomInput, 'id'>> & ExternalGatewayRoomInput> {
  return roomForThread(adapter, event.threadId, event.room ?? event.message?.room)
}

/**
 * Resolves a full room shape from whatever the event carried, deriving the
 * room id from the thread id when the event omitted it.
 *
 * Fields already on the event always win; only the gaps are filled. A network
 * `fetchChannelInfo` is attempted only when something is still missing and the
 * room is not already known to be a named DM, and any fetch failure falls back
 * to the partial shape — room metadata is a nicety, not worth failing ingress.
 */
async function roomForThread(
  adapter: ExternalGatewayAdapter,
  threadId: string,
  room?: ExternalGatewayRoomInput
): Promise<Required<Pick<ExternalGatewayRoomInput, 'id'>> & ExternalGatewayRoomInput> {
  const id = room?.id ?? adapter.channelIdFromThreadId(threadId)
  const fallback = {
    id,
    isDM: room?.isDM ?? adapter.isDM?.(threadId) ?? false,
    metadata: room?.metadata ?? {},
    name: room?.name ?? null,
    raw: room?.raw ?? null,
    roomVisibility: room?.roomVisibility ?? adapter.getChannelVisibility?.(threadId) ?? 'unknown'
  }
  if (fallback.name || fallback.isDM || !adapter.fetchChannelInfo) return fallback

  try {
    const fetched = await adapter.fetchChannelInfo(id)
    return {
      ...fallback,
      isDM: room?.isDM ?? fetched.isDM ?? fallback.isDM,
      metadata: room?.metadata ?? fetched.metadata ?? fallback.metadata,
      name: room?.name ?? fetched.name ?? fallback.name,
      raw: room?.raw ?? fetched.raw ?? fallback.raw,
      roomVisibility: room?.roomVisibility ?? fetched.roomVisibility ?? fallback.roomVisibility
    }
  } catch {
    return fallback
  }
}

function messageJson(message: ExternalGatewayMessageInput, mentions: JsonValue[]): JsonObject {
  return {
    id: message.id,
    threadId: message.threadId,
    text: message.text ?? null,
    authorId: message.author.userId,
    author: toJsonObject(message.author),
    attachments: toJsonArray(message.attachments ?? []),
    links: toJsonArray(message.links ?? []),
    metadata: toJsonObject(message.metadata ?? {}),
    mentions
  }
}

function roomJson(room: Required<Pick<ExternalGatewayRoomInput, 'id'>> & ExternalGatewayRoomInput): JsonObject {
  return {
    id: room.id,
    isDM: room.isDM ?? false,
    roomVisibility: room.roomVisibility ?? 'unknown',
    name: room.name ?? null,
    metadata: toJsonObject(room.metadata ?? {}),
    raw: toJsonValue(room.raw)
  }
}

function actorKeyFromMessage(message: ExternalGatewayMessageInput): string {
  return message.userKey ?? message.author.userId ?? 'unknown'
}

/**
 * Builds the stable provider event id used as the enqueue idempotency key.
 *
 * Shape is `type:room:message:revision`. Tying the key to (type, room, message)
 * is what makes provider redelivery a no-op; the optional revision separates
 * repeated lifecycle events on the same message (e.g. delete then recall).
 */
function providerEventId(
  type: ExternalGatewayCanonicalType,
  roomId: string,
  messageId: string,
  revision?: unknown
): string {
  const suffix = revision instanceof Date ? revision.toISOString() : revision === undefined ? '' : String(revision)
  return `${type}:${roomId}:${messageId}:${suffix}`
}

/**
 * Picks the value that distinguishes one deletion of a message from another.
 *
 * Prefers the explicit delete time; otherwise digs the provider event id out of
 * the raw payload (Lark nests it under `header.event_id`). Returns undefined
 * when neither exists, which collapses repeated identical deletes into one
 * event — acceptable, since the compensating effect is the same.
 */
function deletionRevision(event: ExternalGatewayMessageDeletedEvent): unknown {
  if (event.deletedAt) return event.deletedAt

  const raw = event.raw
  if (typeof raw === 'object' && raw !== null) {
    const record = raw as Record<string, unknown>
    const eventId = record.event_id ?? (record.header as Record<string, unknown> | undefined)?.event_id
    if (typeof eventId === 'string' && eventId.length > 0) return eventId
  }

  return undefined
}

/**
 * Synthesizes a minimal bot-mention entry when the adapter only told us "this
 * mentions the bot" without a structured mentions list, so downstream code can
 * treat mention presence uniformly.
 */
function mentionsFromMessage(message: Pick<ExternalGatewayMessageInput, 'isMention'>): JsonValue[] {
  if (!message.isMention) return []

  return [
    {
      kind: 'bot',
      source: 'adapter_is_mention'
    }
  ]
}

/**
 * Detects whether a message is one of the supported control slash commands
 * (`/new`, `/compress`, `/retry`, `/steer`, `/stop`) and parses it into a stub.
 *
 * Returns undefined for ordinary text. The stub is deliberately shallow
 * (`status: 'stub'`): this is just classification at ingress, and the executor
 * is what actually interprets the command. The command always takes precedence
 * over treating the same text as a normal model message.
 */
export function commandFromMessage(
  message: Pick<ExternalGatewayMessageInput, 'isMention' | 'text'>
): ExternalGatewaySlashCommandStub | undefined {
  const text = message.text?.trim()
  if (!text) return undefined

  const commandText = normalizedCommandText(message, text)
  // `s` so the argument may span newlines: a multi-line `/steer <instruction>`
  // (or `/new <multi-line message>`) must still classify as a slash command
  // rather than leaking the literal command token into the model as normal text.
  const match = /^\/(new|compress|retry|steer|stop)(?:\s+(.*))?$/is.exec(commandText)
  if (!match) return undefined

  return {
    argsText: match[2]?.trim() ?? '',
    name: match[1]!.toLowerCase() as ExternalGatewaySlashCommandStub['name'],
    raw: commandText,
    status: 'stub'
  }
}

/**
 * Strips a leading @mention so "@bot /steer ..." still parses as a command.
 *
 * Only does this for mention messages whose text does not already start with a
 * slash: in many platforms an @mention prefixes the visible text, and without
 * this the command token would never reach `commandFromMessage`'s regex.
 */
function normalizedCommandText(message: Pick<ExternalGatewayMessageInput, 'isMention'>, text: string): string {
  if (text.startsWith('/')) return text
  if (message.isMention !== true) return text

  const match = /^@\S+\s+(\/\S[\s\S]*)$/u.exec(text)
  return match?.[1]?.trim() ?? text
}

/**
 * Tells whether a receive for this message already left the batch window, i.e.
 * its row is no longer `pending`.
 *
 * Used by the delete/recall handler to decide whether the agent has actually
 * seen the message and therefore needs a compensating lifecycle event, versus a
 * message that can still be quietly dropped from the pending window.
 */
async function hasDeliveredReceive(
  agentUid: string,
  bindingName: string,
  providerRoomId: string,
  providerMessageId: string
): Promise<boolean> {
  const rows = await DB.select({ providerEventId: ExternalGatewayAgentEvents.providerEventId })
    .from(ExternalGatewayAgentEvents)
    .where(
      and(
        eq(ExternalGatewayAgentEvents.agentUid, agentUid),
        eq(ExternalGatewayAgentEvents.bindingName, bindingName),
        eq(ExternalGatewayAgentEvents.providerRoomId, providerRoomId),
        eq(ExternalGatewayAgentEvents.providerMessageId, providerMessageId),
        eq(ExternalGatewayAgentEvents.type, 'message.received'),
        ne(ExternalGatewayAgentEvents.status, 'pending')
      )
    )
    .limit(1)

  return rows.length > 0
}

/**
 * Lets an adapter offload handler work to the background.
 *
 * When the adapter passes `runInBackground`, the handler promise is handed off
 * and this resolves immediately, so the adapter can ack the provider webhook
 * inside its tight timeout instead of waiting for projection/enqueue. Otherwise
 * the caller awaits the handler directly.
 */
function runWithWebhookOptions(task: Promise<void>, options?: ExternalGatewayWebhookOptions): Promise<void> {
  if (!options?.runInBackground) return task

  options.runInBackground(task)
  return Promise.resolve()
}
