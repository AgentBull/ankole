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
import { chatGatewayMessageLifecycleSink, type ChatGatewayMessageLifecycleSink } from './core/message-lifecycle'
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
    await handleAddressedMessage(thread, message, agent, projection, lifecycle)
  })

  chat.onDirectMessage(async (thread, message) => {
    await thread.subscribe()
    await handleAddressedMessage(thread, message, agent, projection, lifecycle)
  })

  chat.onSubscribedMessage(async (thread, message) => {
    await handleAddressedMessage(thread, message, agent, projection, lifecycle)
  })

  chat.onAmbientMessage(async (thread, message) => {
    await handleAmbientMessage(thread, message, agent, projection, lifecycle)
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
 * Adapters are responsible for parsing platform events into Chat SDK objects.
 * Once a handler runs, the host has the canonical `Thread` and `Message`, so
 * projection belongs here instead of inside each plugin. That keeps
 * `chat_channels`/`chat_messages` keyed by Chat SDK channel/message identity
 * rather than by local adapter factory ids or console channel names.
 */
async function handleAddressedMessage(
  thread: AnyThread,
  message: AnyMessage,
  agent: AgentResult,
  projection: ChatGatewayProjectionSink,
  lifecycle: ChatGatewayMessageLifecycleSink
): Promise<void> {
  if (await isDeletedInbound(thread, message, agent, lifecycle)) return

  await projection.projectMessage({ thread, message })
  const reply = await postEcho(thread, message, agent)
  try {
    const record = await lifecycle.recordReply({
      agentUid: agent.agent.uid,
      inboundChannelId: channelIdFromThread(thread),
      inboundThreadId: thread.id,
      inboundMessageId: message.id,
      replyThreadId: reply.threadId || thread.id,
      replyMessageId: reply.id
    })

    if (!record.recorded) {
      await projection.projectDelete({ thread, messageId: message.id })
      await deleteProjectedReply(thread, reply, projection)
      return
    }
  } catch (error) {
    await deleteProjectedReply(thread, reply, projection)
    throw error
  }
}

async function handleAmbientMessage(
  thread: AnyThread,
  message: AnyMessage,
  agent: AgentResult,
  projection: ChatGatewayProjectionSink,
  lifecycle: ChatGatewayMessageLifecycleSink
): Promise<void> {
  if (await isDeletedInbound(thread, message, agent, lifecycle)) return

  await projection.projectMessage({ thread, message })
}

async function handleMessageEdited(
  event: MessageEditedEvent,
  agent: AgentResult,
  projection: ChatGatewayProjectionSink,
  lifecycle: ChatGatewayMessageLifecycleSink
): Promise<void> {
  const addressed = isAddressed(event.thread, event.message)
  const result = await lifecycle.updateInboundMessage({
    agentUid: agent.agent.uid,
    channelId: channelIdFromThread(event.thread),
    messageId: event.messageId,
    thread: event.thread,
    message: event.message
  })

  if (!result.handled) {
    if (addressed) {
      await handleAddressedMessage(event.thread, event.message, agent, projection, lifecycle)
      return
    }

    await handleAmbientMessage(event.thread, event.message, agent, projection, lifecycle)
    return
  }

  if (result.reply?.kind === 'create') {
    await handleAddressedMessage(event.thread, event.message, agent, projection, lifecycle)
    return
  }

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
    return
  }

  if (result.reply?.kind === 'edit') {
    let rawMessage: { raw: unknown }
    try {
      const editMessage = requireOutboundCapability(
        event.adapter,
        'edit_message',
        event.adapter.editMessage?.bind(event.adapter)
      )
      rawMessage = await editMessage(result.reply.threadId, result.reply.messageId, result.reply.text)
    } catch (error) {
      if (error instanceof UnsupportedChannelCapabilityError) {
        logger.warn(
          { adapter: event.adapter.name, capability: error.capability, messageId: result.reply.messageId },
          'Chat Gateway reply edit skipped because adapter lacks capability'
        )
        return
      }
      throw error
    }
    await projectReplyText({
      agent,
      adapter: event.adapter,
      projection,
      raw: rawMessage.raw,
      text: result.reply.text,
      thread: event.thread,
      threadId: result.reply.threadId,
      messageId: result.reply.messageId,
      editedAt: new Date()
    })
    await lifecycle.markReplyReconciled({
      agentUid: agent.agent.uid,
      inboundChannelId: channelIdFromThread(event.thread),
      inboundThreadId: event.thread.id,
      inboundMessageId: event.messageId,
      replyThreadId: result.reply.threadId,
      replyMessageId: result.reply.messageId
    })
    return
  }
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
async function postEcho(thread: AnyThread, message: AnyMessage, agent: AgentResult) {
  return thread.post(echoPlaceholderText(agent.agent.uid, message.text))
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

function isAddressed(thread: AnyThread, message: AnyMessage): boolean {
  return thread.channel.isDM || message.isMention === true
}

async function isDeletedInbound(
  thread: AnyThread,
  message: AnyMessage,
  agent: AgentResult,
  lifecycle: ChatGatewayMessageLifecycleSink
): Promise<boolean> {
  return lifecycle.isDeleted({
    agentUid: agent.agent.uid,
    channelId: channelIdFromThread(thread),
    messageId: message.id
  })
}

function channelIdFromThread(thread: AnyThread): string {
  return thread.channel.id || thread.channelId
}
