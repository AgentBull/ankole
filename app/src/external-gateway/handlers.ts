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

export interface RuntimeExternalBinding extends AgentExternalBinding {
  groupMessageMode: GroupMessageMode
}

export interface CreateExternalGatewayAdapterContextInput {
  adapter: ExternalGatewayAdapter
  agent: AgentResult
  binding: RuntimeExternalBinding
  eventQueue: DrizzleExternalGatewayAgentEventQueue
  logger?: Logger
  projection: ExternalGatewayProjectionSink
  getComputerFileWriter?(agentUid: string, signal?: AbortSignal): Promise<ExternalMediaComputerWriter>
  scheduleDrain(availableAt?: Date): void
  /** Reads the executor's pending-clarify gate so group replies can be routed in. */
  roomHasPendingClarify?(providerRoomId: string): boolean
}

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
  if (args.length === 1 && isPlainObject(args[0])) return args[0]
  return { args: [...args] }
}

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
  // pending-clarify gate: a group reply (even non-@mention) must reach the parked
  // clarify's text-intercept in acceptAddressed, so upgrade it to addressed when this
  // room is awaiting an answer. The registry is single-shot — the first answer wins
  // and closes the gate; slash commands are still detected below and take precedence.
  if (delivery !== 'addressed' && Boolean(message.text?.trim()) && runtime.roomHasPendingClarify?.(room.id) === true) {
    delivery = 'addressed'
  }
  runtime.logger?.debug?.(
    {
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
    },
    'External Gateway inbound message delivery decision'
  )
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

  const event =
    command !== undefined
      ? await runtime.eventQueue.enqueue({
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
        ? await runtime.eventQueue.enqueue({
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

  runtime.scheduleDrain(event.availableAt)
}

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
  runtime.logger?.debug?.(
    {
      agentUid: runtime.agent.agent.uid,
      type,
      messageId: event.messageId,
      roomId: room.id,
      delivered
    },
    'External Gateway message lifecycle delivered receive lookup completed'
  )
  if (!delivered) return

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

function providerEventId(
  type: ExternalGatewayCanonicalType,
  roomId: string,
  messageId: string,
  revision?: unknown
): string {
  const suffix = revision instanceof Date ? revision.toISOString() : revision === undefined ? '' : String(revision)
  return `${type}:${roomId}:${messageId}:${suffix}`
}

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

function mentionsFromMessage(message: Pick<ExternalGatewayMessageInput, 'isMention'>): JsonValue[] {
  if (!message.isMention) return []

  return [
    {
      kind: 'bot',
      source: 'adapter_is_mention'
    }
  ]
}

function commandFromMessage(
  message: Pick<ExternalGatewayMessageInput, 'text'>
): ExternalGatewaySlashCommandStub | undefined {
  const text = message.text?.trim()
  if (!text) return undefined

  const match = /^\/(new|compress|retry|steer|stop)(?:\s+(.*))?$/i.exec(text)
  if (!match) return undefined

  return {
    argsText: match[2]?.trim() ?? '',
    name: match[1]!.toLowerCase() as ExternalGatewaySlashCommandStub['name'],
    raw: text,
    status: 'stub'
  }
}

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

function runWithWebhookOptions(task: Promise<void>, options?: ExternalGatewayWebhookOptions): Promise<void> {
  if (!options?.runInBackground) return task

  options.runInBackground(task)
  return Promise.resolve()
}
