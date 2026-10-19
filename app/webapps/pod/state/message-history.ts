import type { ConversationDetail } from '../api'

/** Replace the server's read interval, preserving history already read outside it. */
export function mergeMessageWindow(
  current: ConversationDetail | undefined,
  incoming: ConversationDetail,
  older = false
): ConversationDetail {
  if (!current || current.conversation.id !== incoming.conversation.id) return incoming
  const range = incoming.messageRange
  if (!older && range.firstSeq > current.messageRange.lastSeq + 1) return incoming
  const removed = new Set([...(current.removedMessageIDs ?? []), ...(incoming.removedMessageIDs ?? [])])
  const retained = current.messages.filter(
    message => !removed.has(message.id) && (message.seq < range.firstSeq || message.seq > range.lastSeq)
  )
  const messages = [...retained, ...incoming.messages.filter(message => !removed.has(message.id))].sort(
    (a, b) => a.seq - b.seq
  )
  return {
    ...(older ? current : incoming),
    messages,
    removedMessageIDs: [...removed],
    olderMessagesBeforeSeq:
      current.messageRange.firstSeq < range.firstSeq ? current.olderMessagesBeforeSeq : incoming.olderMessagesBeforeSeq,
    messageRange: {
      firstSeq: Math.min(current.messageRange.firstSeq, range.firstSeq),
      lastSeq: Math.max(current.messageRange.lastSeq, range.lastSeq)
    }
  }
}
