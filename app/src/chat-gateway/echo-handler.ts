import type { Adapter, Chat, Message, Thread } from 'chat'
import type { AgentResult } from '@/principals/agents/service'

type AgentChat = Chat<Record<string, Adapter>>

/**
 * Registers the V1 placeholder behavior for every agent Chat instance.
 *
 * This is intentionally not the future BullX LLM loop. It only proves the user
 * story that inbound IM messages can reach the agent boundary and visible
 * replies can go back through the same Chat SDK thread.
 */
export function registerEchoPlaceholderHandlers(chat: AgentChat, agent: AgentResult): void {
  // A new mention or DM opts the thread into follow-up handling. Chat SDK then
  // routes later messages in the same thread to `onSubscribedMessage`.
  chat.onNewMention(async (thread, message) => {
    await thread.subscribe()
    await postEcho(thread, message, agent)
  })

  chat.onDirectMessage(async (thread, message) => {
    await thread.subscribe()
    await postEcho(thread, message, agent)
  })

  chat.onSubscribedMessage(async (thread, message) => {
    await postEcho(thread, message, agent)
  })
}

/**
 * Sends a visibly temporary response so users do not mistake V1 for an LLM
 * backed agent runtime.
 */
async function postEcho(thread: Thread, message: Message, agent: AgentResult): Promise<void> {
  const text = message.text.trim()
  const suffix = text ? `\n\n${text}` : ''
  await thread.post(`[BullX Agent Chat Gateway V1 echo placeholder:${agent.agent.uid}]${suffix}`)
}
