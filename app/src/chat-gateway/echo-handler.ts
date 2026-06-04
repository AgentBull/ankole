import {
  Message,
  UnsupportedChannelCapabilityError,
  parseMarkdown,
  requireOutboundCapability,
  type Adapter,
  type Chat,
  type MessageDeletedEvent,
  type MessageEditedEvent,
  type Thread
} from './core'
import type { AgentResult } from '@/principals/agents/service'
import { logger } from '@/common/logger'
import { echoPlaceholderText } from './core/echo-text'
import {
  chatGatewayMessageLifecycleSink,
  type ChatGatewayMessageLifecycleReplyAction,
  type ChatGatewayMessageLifecycleSink
} from './core/message-lifecycle'
import type { ChatGatewayProjectionSink } from './core/projection'

type AgentChat = Chat<Record<string, Adapter>>
type AnyThread = Thread<any>
type AnyMessage = Message<any>

/**
 * Registers the V1 placeholder behavior for every agent Chat instance.
 *
 * This is intentionally not the future BullX LLM loop. It only proves the user
 * story that inbound IM messages can reach the agent boundary, are mirrored in
 * BullX's latest-state chat tables, and visible replies can go back through the
 * same Chat SDK thread.
 */
export function registerEchoPlaceholderHandlers(
  chat: AgentChat,
  agent: AgentResult,
  projection: ChatGatewayProjectionSink,
  lifecycle: ChatGatewayMessageLifecycleSink = chatGatewayMessageLifecycleSink
): void {
  chat.onNewMention(async (thread, message) => {
    await thread.subscribe()
    await handleInboundMessage(thread, message, agent, projection, lifecycle)
  })

  chat.onDirectMessage(async (thread, message) => {
    await thread.subscribe()
    await handleInboundMessage(thread, message, agent, projection, lifecycle)
  })

  chat.onSubscribedMessage(async (thread, message) => {
    await handleInboundMessage(thread, message, agent, projection, lifecycle)
  })

  chat.onAmbientMessage(async (thread, message) => {
    await handleInboundMessage(thread, message, agent, projection, lifecycle)
  })

  chat.onMessageEdited(async event => {
    await handleMessageEdited(event, agent, projection, lifecycle)
  })

  chat.onMessageDeleted(async event => {
    await handleMessageDeleted(event, agent, projection, lifecycle)
  })

  chat.onReaction(async event => {
    await projection.projectReaction(event)
  })
}

/**
 * Mirrors accepted inbound Chat SDK messages at the host boundary.
 *
 * Ordinary receives and edit lifecycle events intentionally converge here. The
 * first invariant is durable inbound latest-state projection; only after that
 * has succeeded do we attempt any external reply side effect. That keeps
 * `chat_messages` usable as long-term memory even when a provider post/edit/
 * delete call fails and must be retried by a later webhook.
 */
async function handleInboundMessage(
  thread: AnyThread,
  message: AnyMessage,
  agent: AgentResult,
  projection: ChatGatewayProjectionSink,
  lifecycle: ChatGatewayMessageLifecycleSink
): Promise<void> {
  const channelId = channelIdFromThread(thread)
  const result = await lifecycle.updateInboundMessage({
    agentUid: agent.agent.uid,
    channelId,
    messageId: message.id,
    thread,
    message
  })

  if (result.reply) {
    await applyReplyAction({
      action: result.reply,
      adapter: adapterFromThread(thread),
      agent,
      inboundThread: thread,
      inboundMessage: message,
      lifecycle,
      projection
    })
  }
}

async function handleMessageEdited(
  event: MessageEditedEvent,
  agent: AgentResult,
  projection: ChatGatewayProjectionSink,
  lifecycle: ChatGatewayMessageLifecycleSink
): Promise<void> {
  const result = await lifecycle.updateInboundMessage({
    agentUid: agent.agent.uid,
    channelId: channelIdFromThread(event.thread),
    messageId: event.messageId,
    thread: event.thread,
    message: event.message
  })

  if (result.reply) {
    await applyReplyAction({
      action: result.reply,
      adapter: event.adapter,
      agent,
      inboundThread: event.thread,
      inboundMessage: event.message,
      lifecycle,
      projection
    })
  }
}

async function applyReplyAction(input: {
  action: ChatGatewayMessageLifecycleReplyAction
  adapter?: Adapter
  agent: AgentResult
  inboundThread: AnyThread
  inboundMessage: AnyMessage
  lifecycle: ChatGatewayMessageLifecycleSink
  projection: ChatGatewayProjectionSink
}): Promise<void> {
  if (input.action.kind === 'create') {
    await createLinkedReply({
      action: input.action,
      agent: input.agent,
      inboundThread: input.inboundThread,
      inboundMessage: input.inboundMessage,
      lifecycle: input.lifecycle,
      projection: input.projection
    })
    return
  }

  if (input.action.kind === 'delete') {
    if (!input.adapter) {
      logger.warn(
        { messageId: input.action.messageId },
        'Chat Gateway reply delete skipped because the thread adapter is unavailable'
      )
      return
    }

    await deleteLinkedReply({
      adapter: input.adapter,
      agentUid: input.agent.agent.uid,
      inboundThread: input.inboundThread,
      lifecycle: input.lifecycle,
      projection: input.projection,
      replyThreadId: input.action.threadId,
      replyMessageId: input.action.messageId,
      channelId: channelIdFromThread(input.inboundThread),
      messageId: input.inboundMessage.id
    })
    return
  }

  if (!input.adapter) {
    logger.warn(
      { messageId: input.action.messageId },
      'Chat Gateway reply edit skipped because the thread adapter is unavailable'
    )
    return
  }

  await editLinkedReply({
    adapter: input.adapter,
    agent: input.agent,
    inboundThread: input.inboundThread,
    lifecycle: input.lifecycle,
    projection: input.projection,
    replyThreadId: input.action.threadId,
    replyMessageId: input.action.messageId,
    text: input.action.text,
    channelId: channelIdFromThread(input.inboundThread),
    messageId: input.inboundMessage.id
  })
}

async function createLinkedReply(input: {
  action: Extract<ChatGatewayMessageLifecycleReplyAction, { kind: 'create' }>
  agent: AgentResult
  inboundThread: AnyThread
  inboundMessage: AnyMessage
  lifecycle: ChatGatewayMessageLifecycleSink
  projection: ChatGatewayProjectionSink
}): Promise<void> {
  const claim = {
    agentUid: input.agent.agent.uid,
    channelId: channelIdFromThread(input.inboundThread),
    messageId: input.inboundMessage.id
  }

  if (!(await input.lifecycle.claimReplyCreation(claim))) return

  let reply:
    | {
        delete?: () => Promise<void>
        id: string
        threadId?: string
      }
    | undefined

  try {
    if (await input.lifecycle.isDeleted(claim)) return

    const latest = await input.lifecycle.getProjectedInboundMessage(claim)
    if (!latest || !isProjectedStateAddressed(input.inboundThread, latest.isMention)) return

    try {
      reply = await postEchoText(input.inboundThread, echoPlaceholderText(input.agent.agent.uid, latest.text ?? ''))
    } catch (error) {
      if (error instanceof UnsupportedChannelCapabilityError) {
        logger.warn(
          { capability: error.capability, messageId: input.inboundMessage.id },
          'Chat Gateway reply create skipped because adapter lacks capability'
        )
        return
      }
      throw error
    }

    const record = await input.lifecycle.recordReply({
      agentUid: input.agent.agent.uid,
      inboundChannelId: claim.channelId,
      inboundThreadId: input.inboundThread.id,
      inboundMessageId: input.inboundMessage.id,
      replyThreadId: reply.threadId || input.inboundThread.id,
      replyMessageId: reply.id
    })

    if (!record.recorded) {
      await deleteProjectedReply(input.inboundThread, reply, input.projection)
    }
  } catch (error) {
    if (reply) await deleteProjectedReply(input.inboundThread, reply, input.projection)
    throw error
  } finally {
    await input.lifecycle.releaseReplyCreation(claim)
  }
}

async function editLinkedReply(input: {
  adapter: Adapter
  agent: AgentResult
  channelId: string
  inboundThread: AnyThread
  lifecycle: ChatGatewayMessageLifecycleSink
  messageId: string
  projection: ChatGatewayProjectionSink
  replyMessageId: string
  replyThreadId: string
  text: string
}): Promise<void> {
  let rawMessage: { raw: unknown }
  try {
    const editMessage = requireOutboundCapability(
      input.adapter,
      'edit_message',
      input.adapter.editMessage?.bind(input.adapter)
    )
    rawMessage = await editMessage(input.replyThreadId, input.replyMessageId, input.text)
  } catch (error) {
    if (error instanceof UnsupportedChannelCapabilityError) {
      logger.warn(
        { adapter: input.adapter.name, capability: error.capability, messageId: input.replyMessageId },
        'Chat Gateway reply edit skipped because adapter lacks capability'
      )
      return
    }
    throw error
  }

  await projectReplyText({
    agent: input.agent,
    adapter: input.adapter,
    projection: input.projection,
    raw: rawMessage.raw,
    text: input.text,
    thread: input.inboundThread,
    threadId: input.replyThreadId,
    messageId: input.replyMessageId,
    editedAt: new Date()
  })
  await input.lifecycle.markReplyReconciled({
    agentUid: input.agent.agent.uid,
    inboundChannelId: input.channelId,
    inboundThreadId: input.inboundThread.id,
    inboundMessageId: input.messageId,
    replyThreadId: input.replyThreadId,
    replyMessageId: input.replyMessageId
  })
}

async function handleMessageDeleted(
  event: MessageDeletedEvent,
  agent: AgentResult,
  projection: ChatGatewayProjectionSink,
  lifecycle: ChatGatewayMessageLifecycleSink
): Promise<void> {
  await projection.projectDelete({ thread: event.thread, messageId: event.messageId })
  const result = await lifecycle.deleteInboundMessage({
    agentUid: agent.agent.uid,
    channelId: channelIdFromThread(event.thread),
    messageId: event.messageId
  })

  if (result.reply?.kind === 'delete') {
    await deleteLinkedReply({
      adapter: event.adapter,
      agentUid: agent.agent.uid,
      inboundThread: event.thread,
      lifecycle,
      projection,
      replyThreadId: result.reply.threadId,
      replyMessageId: result.reply.messageId,
      channelId: channelIdFromThread(event.thread),
      messageId: event.messageId
    })
  }
}

/**
 * Sends a visibly temporary response so users do not mistake V1 for an LLM
 * backed agent runtime.
 */
async function postEchoText(thread: AnyThread, text: string) {
  return thread.post(text)
}

async function deleteLinkedReply(input: {
  adapter: Adapter
  agentUid: string
  channelId: string
  inboundThread: AnyThread
  lifecycle: ChatGatewayMessageLifecycleSink
  messageId: string
  projection: ChatGatewayProjectionSink
  replyMessageId: string
  replyThreadId: string
}): Promise<void> {
  try {
    const deleteMessage = requireOutboundCapability(
      input.adapter,
      'delete_message',
      input.adapter.deleteMessage?.bind(input.adapter)
    )
    await deleteMessage(input.replyThreadId, input.replyMessageId)
  } catch (error) {
    if (error instanceof UnsupportedChannelCapabilityError) {
      logger.warn(
        { adapter: input.adapter.name, capability: error.capability, messageId: input.replyMessageId },
        'Chat Gateway reply delete skipped because adapter lacks capability'
      )
      return
    }
    throw error
  }

  await input.projection.projectDelete({
    thread: threadForMessage(input.inboundThread, input.replyThreadId),
    messageId: input.replyMessageId
  })
  await input.lifecycle.forgetReply({
    agentUid: input.agentUid,
    channelId: input.channelId,
    messageId: input.messageId
  })
}

async function projectReplyText(input: {
  agent: AgentResult
  adapter: Adapter
  projection: ChatGatewayProjectionSink
  raw: unknown
  text: string
  thread: AnyThread
  threadId: string
  messageId: string
  editedAt?: Date
}): Promise<void> {
  await input.projection.projectMessage({
    thread: threadForMessage(input.thread, input.threadId),
    message: new Message({
      id: input.messageId,
      threadId: input.threadId,
      text: input.text,
      formatted: parseMarkdown(input.text),
      raw: input.raw,
      author: {
        userId: 'self',
        userName: input.adapter.userName || input.agent.agent.uid,
        fullName: input.adapter.userName || input.agent.agent.uid,
        isBot: true,
        isMe: true
      },
      metadata: {
        // On updates, projection preserves the original sent_at if a row already
        // exists. This fallback only applies if BullX missed the original reply
        // projection and first observes the reply through an edit.
        dateSent: input.editedAt ?? new Date(),
        edited: input.editedAt !== undefined,
        editedAt: input.editedAt
      },
      attachments: [],
      links: []
    })
  })
}

async function deleteProjectedReply(
  thread: AnyThread,
  reply: { delete?: () => Promise<void>; id: string; threadId?: string },
  projection: ChatGatewayProjectionSink
): Promise<void> {
  const deleted = await deleteSentReply(reply)
  if (!deleted) return
  await projection.projectDelete({
    thread: threadForMessage(thread, reply.threadId || thread.id),
    messageId: reply.id
  })
}

async function deleteSentReply(reply: { delete?: () => Promise<void>; id?: string }): Promise<boolean> {
  if (typeof reply.delete !== 'function') return false

  try {
    await reply.delete()
    return true
  } catch (error) {
    if (error instanceof UnsupportedChannelCapabilityError) {
      logger.warn(
        { capability: error.capability, messageId: reply.id },
        'Chat Gateway temporary reply cleanup skipped because adapter lacks capability'
      )
      return false
    }
    throw error
  }
}

function threadForMessage(thread: AnyThread, threadId: string): AnyThread {
  if (thread.id === threadId) return thread

  return {
    ...thread,
    id: threadId,
    channelId: channelIdFromThread(thread),
    channel: thread.channel
  }
}

function adapterFromThread(thread: AnyThread): Adapter | undefined {
  const maybeThread = thread as { adapter?: Adapter }
  return maybeThread.adapter
}

function isProjectedStateAddressed(thread: AnyThread, isMention: boolean): boolean {
  return thread.channel.isDM || isMention
}

function channelIdFromThread(thread: AnyThread): string {
  return thread.channel.id || thread.channelId
}
