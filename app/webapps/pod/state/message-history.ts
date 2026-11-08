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
  const removed = new Set([...current.removedMessageIDs, ...incoming.removedMessageIDs])
  const retained = current.messages.filter(
    message => !removed.has(message.id) && (message.seq < range.firstSeq || message.seq > range.lastSeq)
  )
  const messages = [...retained, ...incoming.messages.filter(message => !removed.has(message.id))].sort(
    (a, b) => a.seq - b.seq
  )
  const retainedIDs = new Set(retained.map(message => message.id))
  const seqByID = new Map(messages.map(message => [message.id, message.seq]))
  const viewerUID = (older ? current : incoming).conversation.viewer.uid
  const maxOtherHumanSeq = messages.reduce(
    (max, message) =>
      message.authorType === 'human' && message.authorUID && message.authorUID !== viewerUID
        ? Math.max(max, message.seq)
        : max,
    -Infinity
  )
  const retainedEditable = (current.editableInputs ?? []).filter(entry => retainedIDs.has(entry.messageID))
  const incomingEditable = (incoming.editableInputs ?? []).filter(entry => seqByID.has(entry.messageID))
  const editableMap = new Map<string, ConversationDetail['editableInputs'][number]>()
  for (const entry of older ? [...incomingEditable, ...retainedEditable] : [...retainedEditable, ...incomingEditable]) {
    const previous = editableMap.get(entry.messageID)
    const seq = seqByID.get(entry.messageID) ?? Infinity
    editableMap.set(entry.messageID, {
      ...entry,
      supersededByParticipant:
        entry.supersededByParticipant || (previous?.supersededByParticipant ?? false) || seq < maxOtherHumanSeq
    })
  }
  return {
    ...(older ? current : incoming),
    messages,
    editableInputs: [...editableMap.values()],
    removedMessageIDs: [...removed],
    olderMessagesBeforeSeq:
      current.messageRange.firstSeq < range.firstSeq ? current.olderMessagesBeforeSeq : incoming.olderMessagesBeforeSeq,
    messageRange: {
      firstSeq: Math.min(current.messageRange.firstSeq, range.firstSeq),
      lastSeq: Math.max(current.messageRange.lastSeq, range.lastSeq)
    }
  }
}
