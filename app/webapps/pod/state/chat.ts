import { equal, uuidV4 } from '@agentbull/active-support'
import { batch, computed, createModel, signal } from '@preact/signals-react'
import type {
  ConversationMessage,
  ConversationDetail,
  ConversationPendingInput,
  ConversationQueueRequest,
  MessageSubmission,
  PodActivity
} from '../api'
import type { TimelineLiveStream } from '../chat/types'
import { ChatAttachments } from './chat-attachments'

export type PendingMessage = MessageSubmission & { state: 'sending' | 'failed' }
type ChatLinks = NonNullable<MessageSubmission['links']>
type ChatMentions = NonNullable<MessageSubmission['mentions']>
export type ChatEditSnapshot = { text: string; links: ChatLinks; mentions: ChatMentions }
type ChatEditing = {
  messageID: string
  previousDraft: string
  previousLinks: ChatLinks
  previousAnsweringInteractionID?: string
  queueVersion: string
  kind: 'queue' | 'last'
  originalText: string
  originalLinks: ChatLinks
  originalMentions: ChatMentions
  hasAttachments: boolean
  agentUID: string
  commandID?: string
}
/**
 * A draft quotes one passage at a time, a message or a Page selection, beside any number of Page references.
 * `quote` decides which passage stays when the added links bring one: the added one replaces the draft's, or
 * the draft keeps its own. A reference already in the draft is not repeated.
 */
function addLinks(current: ChatLinks, added: ChatLinks, quote: 'replace' | 'keep'): ChatLinks {
  const addedQuote = added.find(link => link.quote != null)
  const currentQuote = current.find(link => link.quote != null)
  const dropped = quote === 'replace' ? currentQuote : addedQuote && currentQuote ? addedQuote : undefined
  const merged = [...current, ...added].filter(link => link !== dropped)
  return merged.filter((link, index) => {
    const sameTarget = (other: ChatLinks[number]) => other.kind === link.kind && other.id === link.id
    const quoted = merged.find(other => sameTarget(other) && other.quote != null)
    return quoted ? link === quoted : merged.findIndex(sameTarget) === index
  })
}

export const draftLinks = (links: ConversationMessage['links']) =>
  links.map(link => ({
    kind: link.kind,
    id: link.id,
    ...(link.quote != null ? { quote: link.quote } : {})
  }))
export const draftMentions = (mentions: ConversationMessage['mentions']): ChatMentions =>
  mentions.flatMap(mention =>
    (mention.type === 'agent' || mention.type === 'human') && typeof mention.uid === 'string'
      ? [
          {
            type: mention.type,
            uid: mention.uid,
            ...(typeof mention.displayName === 'string' ? { displayName: mention.displayName } : {})
          }
        ]
      : []
  )

export function hasDraftMention(text: string, displayName: string) {
  const name = displayName.replace(/[.*+?^${}()|[\]\\]/g, '\\$&')
  return new RegExp(`(?<![\\p{L}\\p{N}_])@${name}(?![\\p{L}\\p{N}_])`, 'u').test(text)
}

export type ChatPresentation = 'page' | 'standalone'
export type ChatReadingPosition = { atBottom: true } | { atBottom: false; messageID: string; offset: number }
export type DisplayMessage =
  | { type: 'committed'; message: ConversationMessage; queued?: boolean }
  | { type: 'pending'; message: PendingMessage }

export function chatRecipientAvailable(
  targetUID: string,
  members: { uid: string; active: boolean }[],
  callableUIDs: string[]
) {
  return (
    !targetUID || members.some(member => member.uid === targetUID && member.active && callableUIDs.includes(member.uid))
  )
}

export function chatCommandPolicy(input: {
  sending: boolean
  queuePending: boolean
  modelSaving: boolean
  available: boolean
  working: boolean
  hasQueued: boolean
  hasSubmission: boolean
}) {
  const disabled = input.sending || input.queuePending || !input.available
  const canRetryLast = !disabled && !input.modelSaving && !input.working && !input.hasQueued
  return {
    disabled,
    canSubmit: !disabled && !input.modelSaving && input.hasSubmission,
    canRetryLast,
    canQueue: (action: ConversationQueueRequest['action']) =>
      !disabled && (!['regenerate', 'edit_last'].includes(action) || !input.modelSaving)
  }
}

/** Derive the view from the remote cache and uncommitted local work. */
export function mergeMessages(
  committed: ConversationMessage[],
  pending: PendingMessage | undefined,
  queues: ConversationDetail['pendingQueues'] = [],
  humanCount = 1
): DisplayMessage[] {
  const queued = new Set(queues.flatMap(queue => queue.inputs.map(input => input.messageID)))
  const latestReply = committed.findLast(message => message.authorType === 'agent' && message.kind === 'message')
  const result: DisplayMessage[] = committed.flatMap(message => {
    if (message.authorType !== 'human' || !queued.has(message.id)) return [{ type: 'committed' as const, message }]
    if (humanCount <= 1 && (!latestReply || latestReply.seq <= message.seq)) return []
    return [{ type: 'committed' as const, message, queued: true }]
  })
  if (pending && !committed.some(message => message.id === pending.messageID)) {
    result.push({ type: 'pending', message: pending })
  }
  return result
}

function replyCommitted(messages: ConversationMessage[], live: Pick<TimelineLiveStream, 'signalIDs'>): boolean {
  return messages.some(
    message =>
      message.signalID != null &&
      live.signalIDs.includes(message.signalID) &&
      (message.authorType === 'agent' || message.kind === 'notice')
  )
}

export function shouldSendOnEnter(event: {
  key: string
  shiftKey: boolean
  isComposing: boolean
  keyCode: number
  ctrlKey?: boolean
  metaKey?: boolean
}): boolean {
  return (
    event.key === 'Enter' &&
    (!event.shiftKey || !!event.ctrlKey || !!event.metaKey) &&
    !event.isComposing &&
    event.keyCode !== 229
  )
}

export const ChatModel = createModel(() => {
  const draft = signal('')
  const attachments = new ChatAttachments()
  const conversationID = signal<string>()
  const selectedAgentUID = signal('')
  const pending = signal<PendingMessage>()
  const liveStreams = signal<Record<string, TimelineLiveStream>>({})
  const activities = signal<Record<string, PodActivity>>({})
  const latestActivities = new Map<string, PodActivity>()
  const observedAt: Record<string, number> = {}
  const mentions = signal<{ type: 'agent' | 'human'; uid: string; displayName: string }[]>([])
  const links = signal<ChatLinks>([])
  const neededInvites = signal<{ uid: string; displayName: string }[]>([])
  const targetAgentUID = signal('')
  const answeringInteractionID = signal<string>()
  let activityObservation = 0
  const error = signal<unknown>()
  const connecting = signal(false)
  const gone = signal(false)
  const reading = signal<Partial<Record<ChatPresentation, ChatReadingPosition>>>({})
  const modelProfile = signal<string | null>(null)
  const editing = signal<ChatEditing>()
  let stopCommandID: string | undefined
  const hasText = computed(() => draft.value.trim().length > 0)
  const hasContent = computed(() => hasText.value || attachments.hasFiles.value)
  const quoted = computed(() => links.value.find(link => link.quote != null))
  const clearCapturedDraft = (capture: Pick<MessageSubmission, 'text' | 'links' | 'mentions'>) => {
    if (
      draft.peek() !== capture.text ||
      !equal(links.peek(), capture.links ?? []) ||
      !equal(mentions.peek(), capture.mentions ?? [])
    ) {
      return
    }
    draft.value = ''
    mentions.value = []
    links.value = []
  }

  return {
    draft,
    attachments,
    conversationID,
    selectedAgentUID,
    pending,
    liveStreams,
    activities,
    mentions,
    links,
    quoted,
    neededInvites,
    targetAgentUID,
    answeringInteractionID,
    error,
    connecting,
    gone,
    reading,
    modelProfile,
    editing,
    hasText,
    hasContent,
    startAnswer(interactionID: string, text = '') {
      if (editing.peek()) return false
      batch(() => {
        if (text) draft.value = draft.peek().trim() ? `${draft.peek()}\n\n${text}` : text
        answeringInteractionID.value = interactionID
      })
      return true
    },
    cancelAnswer() {
      answeringInteractionID.value = undefined
    },
    /** Quote a message or a Page selection in the draft, in place of any passage it quoted before. */
    quote(link: { kind: 'message' | 'page'; id: string; quote: string }) {
      links.value = addLinks(links.peek(), [link], 'replace')
    },
    referencePage(id: string) {
      links.value = addLinks(links.peek(), [{ kind: 'page', id }], 'keep')
    },
    rememberReading(presentation: ChatPresentation, position: ChatReadingPosition | undefined) {
      if (!gone.peek()) reading.value = { ...reading.peek(), [presentation]: position }
    },
    beginEdit(
      context: ChatEditSnapshot &
        Pick<ChatEditing, 'messageID' | 'queueVersion' | 'kind' | 'hasAttachments' | 'agentUID'>
    ) {
      if (editing.peek()) return
      const { messageID, text, queueVersion, kind, hasAttachments, agentUID } = context
      batch(() => {
        editing.value = {
          ...(answeringInteractionID.peek() ? { previousAnsweringInteractionID: answeringInteractionID.peek() } : {}),
          messageID,
          previousDraft: draft.value,
          previousLinks: links.value,
          queueVersion,
          kind,
          originalText: text,
          originalLinks: context.links,
          originalMentions: context.mentions,
          hasAttachments,
          agentUID,
          ...(kind === 'last' ? { commandID: uuidV4() } : {})
        }
        draft.value = text
        answeringInteractionID.value = undefined
        links.value = context.links
      })
    },
    cancelEdit() {
      if (!editing.value) return
      batch(() => {
        draft.value = editing.value!.previousDraft
        links.value = editing.value!.previousLinks
        answeringInteractionID.value = editing.value!.previousAnsweringInteractionID
        editing.value = undefined
      })
    },
    savedEditChanged(saved: ChatEditSnapshot) {
      const current = editing.peek()
      return (
        !!current &&
        (saved.text !== current.originalText ||
          !equal(saved.links, current.originalLinks) ||
          !equal(saved.mentions, current.originalMentions))
      )
    },
    restoreQueuedInput(input: ConversationPendingInput, agentUID: string) {
      const previous = draft.peek()
      const references = draftLinks(input.links)
      const people = input.mentions.flatMap(mention =>
        mention.type === 'human' && mention.displayName
          ? [{ type: 'human' as const, uid: mention.uid, displayName: mention.displayName }]
          : []
      )
      batch(() => {
        draft.value = previous.trim() ? `${previous}\n\n${input.text}` : input.text
        if (!previous.trim()) targetAgentUID.value = agentUID
        links.value = addLinks(links.peek(), references, 'keep')
        mentions.value = [
          ...mentions.peek(),
          ...people.filter(person => !mentions.peek().some(existing => existing.uid === person.uid))
        ]
      })
    },
    rebaseEdit(messageID: string, saved: ChatEditSnapshot, queueVersion: string, useSaved = false) {
      const current = editing.peek()
      if (!current || current.messageID !== messageID) return false
      if (!useSaved && this.savedEditChanged(saved)) return false
      batch(() => {
        editing.value = {
          ...current,
          queueVersion,
          originalText: saved.text,
          originalLinks: saved.links,
          originalMentions: saved.mentions,
          ...(useSaved && current.kind === 'last' ? { commandID: uuidV4() } : {})
        }
        if (useSaved) {
          draft.value = saved.text
          links.value = saved.links
        }
      })
      return true
    },
    editSaved(messageID: string, text: string, savedLinks: ChatLinks = []) {
      if (editing.value?.messageID === messageID && draft.value === text && equal(links.value, savedLinks)) {
        this.cancelEdit()
      }
    },
    editCommand(): ConversationQueueRequest | undefined {
      const current = editing.value
      if (!current) return
      return {
        action: current.kind === 'last' ? 'edit_last' : 'edit',
        agentUID: current.agentUID,
        messageID: current.messageID,
        text: draft.value,
        links: links.value,
        mentions: current.originalMentions.filter(
          mention =>
            mention.type === 'agent' || !mention.displayName || hasDraftMention(draft.value, mention.displayName)
        ),
        expectedVersion: current.queueVersion,
        ...(current.kind === 'last'
          ? {
              expectedText: current.originalText,
              expectedLinks: current.originalLinks,
              expectedMentions: current.originalMentions,
              commandID: current.commandID
            }
          : {})
      }
    },
    stopID(nextID: () => string) {
      stopCommandID ??= nextID()
      return stopCommandID
    },
    controlAccepted() {
      stopCommandID = undefined
    },
    submit(conversationID: string | undefined, agentUID: string, nextID: () => string): MessageSubmission {
      const text = draft.value
      const previous = pending.value
      const capture = attachments.capture()
      const submission =
        previous &&
        previous.text === text &&
        previous.agentUID === agentUID &&
        previous.deliveryMode === 'queue' &&
        previous.modelProfile === modelProfile.value &&
        previous.targetAgentUID === (targetAgentUID.value || undefined) &&
        equal(previous.mentions ?? [], mentions.value) &&
        equal(previous.links ?? [], links.value) &&
        equal(previous.attachmentIDs ?? [], capture.attachmentIDs)
          ? { ...previous, ...capture }
          : {
              conversationID: conversationID ?? nextID(),
              messageID: nextID(),
              agentUID,
              text,
              deliveryMode: 'queue' as const,
              modelProfile: modelProfile.value,
              targetAgentUID: targetAgentUID.value || undefined,
              mentions: mentions.value,
              links: links.value,
              ...capture
            }
      batch(() => {
        pending.value = { ...submission, state: 'sending' }
        error.value = undefined
      })
      return submission
    },
    failed(failure: unknown, messageID: string) {
      // A committed message can permit a newer send before this request finishes.
      if (pending.value?.messageID !== messageID) return
      attachments.rejected(failure, pending.value.attachmentIDs)
      batch(() => {
        pending.value = { ...pending.value!, state: 'failed' }
        error.value = failure
      })
    },
    accepted(submission: MessageSubmission) {
      batch(() => {
        attachments.accepted(submission.attachmentIDs)
        conversationID.value = submission.conversationID
        if (pending.value?.messageID === submission.messageID) {
          pending.value = undefined
          clearCapturedDraft(submission)
          error.value = undefined
        }
      })
    },
    answerAccepted(
      interactionID: string,
      capture: Pick<MessageSubmission, 'text' | 'links' | 'mentions' | 'attachmentIDs'>
    ) {
      batch(() => {
        attachments.accepted(capture.attachmentIDs)
        clearCapturedDraft(capture)
        if (answeringInteractionID.peek() === interactionID) answeringInteractionID.value = undefined
      })
    },
    reconcile(messages: ConversationMessage[]) {
      batch(() => {
        const current = pending.value
        if (current && messages.some(message => message.id === current.messageID)) {
          attachments.accepted(current.attachmentIDs)
          conversationID.value = current.conversationID
          pending.value = undefined
          clearCapturedDraft(current)
          error.value = undefined
        }
        liveStreams.value = Object.fromEntries(
          Object.entries(liveStreams.value).filter(([, stream]) => !replyCommitted(messages, stream))
        )
      })
    },
    started(responseID: string, signalIDs: string[], agentUID: string, agentName?: string, startedAt?: string) {
      if (gone.value) return
      const previous = liveStreams.value[agentUID]
      const sameResponse = previous?.responseID === responseID
      const sameTurn = previous?.signalIDs.some(id => signalIDs.includes(id))
      liveStreams.value = {
        ...liveStreams.value,
        [agentUID]: {
          agentUID,
          agentName: agentName ?? (sameResponse ? previous.agentName : undefined),
          responseID,
          signalIDs,
          text: sameResponse ? previous.text : '',
          thinkingSummary: sameResponse || sameTurn ? previous.thinkingSummary : '',
          startedAt: sameResponse || sameTurn ? (previous.startedAt ?? startedAt) : startedAt
        }
      }
    },
    snapshot(stream: TimelineLiveStream) {
      if (gone.value) return
      const current = liveStreams.value[stream.agentUID]
      if (current && current.responseID !== stream.responseID) return
      liveStreams.value = { ...liveStreams.value, [stream.agentUID]: stream }
    },
    delta(responseID: string, text: string, signalIDs: string[], agentUID: string, reasoning = false) {
      if (gone.value) return
      const current = liveStreams.value[agentUID]
      if (current && current.responseID !== responseID) return
      const next = current ?? { agentUID, responseID, signalIDs, text: '', thinkingSummary: '' }
      liveStreams.value = {
        ...liveStreams.value,
        [agentUID]: {
          ...next,
          ...(reasoning ? { thinkingSummary: next.thinkingSummary + text } : { text: next.text + text })
        }
      }
    },
    settled(responseID: string, agentUID: string) {
      if (liveStreams.value[agentUID]?.responseID === responseID) {
        const next = { ...liveStreams.value }
        delete next[agentUID]
        liveStreams.value = next
      }
    },
    activityRead() {
      return activityObservation
    },
    observeActivity(incoming: PodActivity, readObservation?: number) {
      if (connecting.value && incoming.state === 'active') return
      const uid = incoming.agentUID
      if (gone.value || (readObservation !== undefined && readObservation < (observedAt[uid] ?? 0))) return
      const current = latestActivities.get(uid)
      if (current && incoming.state === 'unavailable' && (incoming.epoch === 0 || incoming.epoch === current.epoch)) {
        incoming = { ...incoming, epoch: current.epoch, revision: Math.max(incoming.revision, current.revision) }
      }
      if (
        current &&
        (incoming.epoch < current.epoch ||
          (incoming.epoch === current.epoch && current.state === 'settled') ||
          (incoming.epoch === current.epoch &&
            incoming.state === 'active' &&
            (incoming.revision < current.revision ||
              (current.state === 'unavailable' &&
                incoming.revision === current.revision &&
                readObservation === undefined))))
      ) {
        return
      }
      observedAt[uid] = ++activityObservation
      latestActivities.set(uid, incoming)
      if (incoming.state !== 'active' || !connecting.peek()) {
        activities.value = { ...activities.value, [uid]: incoming }
      }
      if (incoming.state === 'active' && !connecting.peek() && incoming.responseID && !liveStreams.value[uid]) {
        liveStreams.value = {
          ...liveStreams.value,
          [uid]: {
            agentUID: uid,
            responseID: incoming.responseID,
            signalIDs: incoming.signalID ? [incoming.signalID] : [],
            text: '',
            thinkingSummary: ''
          }
        }
      } else if (
        incoming.state !== 'active' &&
        liveStreams.value[uid] &&
        !liveStreams.value[uid].text &&
        !liveStreams.value[uid].thinkingSummary &&
        !liveStreams.value[uid].startedAt
      ) {
        const next = { ...liveStreams.value }
        delete next[uid]
        liveStreams.value = next
      }
    },
    markGone() {
      latestActivities.clear()
      batch(() => {
        gone.value = true
        reading.value = {}
        liveStreams.value = {}
        activities.value = {}
        connecting.value = false
      })
    },
    disconnected() {
      if (gone.value) return
      activityObservation++
      batch(() => {
        liveStreams.value = {}
        activities.value = {}
        connecting.value = true
      })
    },
    connected() {
      batch(() => {
        liveStreams.value = {}
        connecting.value = false
      })
    }
  }
})
