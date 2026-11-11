import { escapeRegExp } from '../../common/text'
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
  const name = escapeRegExp(displayName)
  return new RegExp(`(?<![\\p{L}\\p{N}_])@${name}(?![\\p{L}\\p{N}_])`, 'u').test(text)
}

export type ChatPresentation = 'page' | 'standalone'
export type ChatReadingPosition = { atBottom: true } | { atBottom: false; messageID: string; offset: number }
export type FollowUpBehavior = 'steer' | 'queue'
export type DisplayMessage =
  | { type: 'committed'; message: ConversationMessage; queued?: boolean }
  | { type: 'pending'; message: PendingMessage }

const FOLLOW_UP_BEHAVIOR_KEY = 'ankole.pod.chat.followUpBehavior'

function readFollowUpBehavior(): FollowUpBehavior {
  try {
    return globalThis.localStorage?.getItem(FOLLOW_UP_BEHAVIOR_KEY) === 'queue' ? 'queue' : 'steer'
  } catch {
    return 'steer'
  }
}

const followUpBehaviorPreference = signal<FollowUpBehavior>(readFollowUpBehavior())

export function queuedInputs(queue: Pick<ConversationDetail['pendingQueues'][number], 'inputs'>) {
  return queue.inputs.filter(input => input.deliveryMode === 'queue')
}

export function resolveFollowUpDeliveryModes(input: {
  working: boolean
  paused: boolean
  canSteer: boolean
  followUpBehavior: FollowUpBehavior
}): { primary: FollowUpBehavior; alternate?: FollowUpBehavior } {
  if (!input.working) {
    return input.paused ? { primary: 'steer', alternate: 'queue' } : { primary: 'steer' }
  }
  if (!input.canSteer) return { primary: 'queue' }
  const primary = input.followUpBehavior
  return { primary, alternate: primary === 'steer' ? 'queue' : 'steer' }
}

export function chatRecipientAvailable(
  targetUID: string,
  members: { uid: string; active: boolean }[],
  callableUIDs: string[]
) {
  return (
    !targetUID || members.some(member => member.uid === targetUID && member.active && callableUIDs.includes(member.uid))
  )
}

/**
 * The Agent that the composer of an Issue's room addresses until the person picks another recipient. A room of one
 * person and the Agent is a `dm`, which addresses its Agent already, so the default matters once the room is a group.
 */
export function issueRecipientUID(
  detail:
    | { issueAgentUID?: string | null; conversation: { roomMode: string; agents: { uid: string; active: boolean }[] } }
    | undefined,
  callableUIDs: string[]
) {
  const uid = detail?.conversation.roomMode === 'group' ? detail.issueAgentUID : undefined
  return uid && chatRecipientAvailable(uid, detail!.conversation.agents, callableUIDs) ? uid : undefined
}

/**
 * Resolves the active recipient selection without copying query state into `ChatModel.targetAgentUID`:
 * `null` follows the room's default Issue Agent, `''` is an explicit group-listeners selection, and any
 * non-empty string is an explicit Agent UID.
 */
export function effectiveTargetAgentUID(
  selectedTargetUID: string | null,
  detail:
    | { issueAgentUID?: string | null; conversation: { roomMode: string; agents: { uid: string; active: boolean }[] } }
    | undefined,
  callableUIDs: string[]
): string {
  if (selectedTargetUID !== null) return selectedTargetUID
  return issueRecipientUID(detail, callableUIDs) ?? ''
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
  const queued = new Set(queues.flatMap(queue => queuedInputs(queue).map(input => input.messageID)))
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

/** The committed message that replaces a live reply: its Agent message, or else the notice that ended its turn. */
function committedReply(messages: ConversationMessage[], live: Pick<TimelineLiveStream, 'signalIDs'>) {
  const replies = messages.filter(
    message =>
      message.signalID != null &&
      live.signalIDs.includes(message.signalID) &&
      (message.authorType === 'agent' || message.kind === 'notice')
  )
  return replies.find(message => message.authorType === 'agent' && message.kind === 'message') ?? replies[0]
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

function composeSkillSubmissionText(rawText: string, skill: { slug: string; name: string } | null): string {
  if (!skill) return rawText
  const trimmed = rawText.trimStart()
  if (trimmed === `/${skill.slug}` || trimmed.startsWith(`/${skill.slug} `) || trimmed.startsWith(`/${skill.slug}\n`)) {
    return rawText
  }
  return rawText ? `/${skill.slug} ${rawText}` : `/${skill.slug}`
}

function createChat() {
  const draft = signal('')
  const attachedSkill = signal<{ slug: string; name: string } | null>(null)
  /** Adds text after what the draft already holds, with a blank line between them. */
  const appendDraft = (text: string) => {
    draft.value = draft.peek().trim() ? `${draft.peek()}\n\n${text}` : text
  }
  const attachments = new ChatAttachments()
  const conversationID = signal<string>()
  const selectedAgentUID = signal('')
  const pending = signal<PendingMessage>()
  const liveStreams = signal<Record<string, TimelineLiveStream>>({})
  /**
   * The timeline renders an Agent's live reply under `live` and the committed message that replaces it under the
   * key that `committed` records, so the reply's content stays mounted and keeps its state. `live` counts each
   * Agent's replaced replies, so that its next reply gets a key of its own.
   */
  const replyKeys = signal<{ live: Record<string, number>; committed: Record<string, string> }>({
    live: {},
    committed: {}
  })
  const liveReplyKey = (agentUID: string, live = replyKeys.value.live) => `live:${agentUID}:${live[agentUID] ?? 0}`
  const activities = signal<Record<string, PodActivity>>({})
  const latestActivities = new Map<string, PodActivity>()
  const observedAt: Record<string, number> = {}
  const mentions = signal<{ type: 'agent' | 'human'; uid: string; displayName: string }[]>([])
  const links = signal<ChatLinks>([])
  const neededInvites = signal<{ uid: string; displayName: string }[]>([])
  const targetAgentUID = signal<string | null>(null)
  const answeringInteractionID = signal<string>()
  let activityObservation = 0
  const error = signal<unknown>()
  const connecting = signal(false)
  const gone = signal(false)
  const reading = signal<Partial<Record<ChatPresentation, ChatReadingPosition>>>({})
  const modelProfile = signal<string | null>(null)
  const editing = signal<ChatEditing>()
  const editDraft = signal('')
  const editLinks = signal<ChatLinks>([])
  const backtrackMessageID = signal<string>()
  const selectingMessages = signal(false)
  const selectedMessageIDs = signal<string[]>([])
  let stopCommandID: string | undefined
  const hasText = computed(() => draft.value.trim().length > 0)
  const hasEditText = computed(() => editDraft.value.trim().length > 0)
  const hasContent = computed(() => hasText.value || attachments.hasFiles.value || attachedSkill.value !== null)
  const quoted = computed(() => links.value.find(link => link.quote != null))
  const editQuoted = computed(() => editLinks.value.find(link => link.quote != null))
  const selectedMessageCount = computed(() => selectedMessageIDs.value.length)
  let previousMentionedAgentUIDs: string[] = []
  const mentionedAgentUIDs = computed(() => {
    const next = mentions.value
      .filter(mention => mention.type === 'agent' && hasDraftMention(draft.value, mention.displayName))
      .map(mention => mention.uid)
    if (equal(previousMentionedAgentUIDs, next)) return previousMentionedAgentUIDs
    previousMentionedAgentUIDs = next
    return next
  })
  const clearCapturedDraft = (capture: Pick<MessageSubmission, 'text' | 'links' | 'mentions'>) => {
    const currentText = draft.peek()
    const currentSkill = attachedSkill.peek()
    const matchesText =
      currentText === capture.text || composeSkillSubmissionText(currentText, currentSkill) === capture.text
    if (!matchesText || !equal(links.peek(), capture.links ?? []) || !equal(mentions.peek(), capture.mentions ?? [])) {
      return
    }
    draft.value = ''
    attachedSkill.value = null
    mentions.value = []
    links.value = []
  }

  const cancelEdit = () => {
    const current = editing.peek()
    if (!current) return
    batch(() => {
      if (current.kind === 'last') {
        editDraft.value = ''
        editLinks.value = []
      } else {
        draft.value = current.previousDraft
        links.value = current.previousLinks
        answeringInteractionID.value = current.previousAnsweringInteractionID
      }
      editing.value = undefined
    })
  }
  const savedEditChanged = (saved: ChatEditSnapshot) => {
    const current = editing.peek()
    return (
      !!current &&
      (saved.text !== current.originalText ||
        !equal(saved.links, current.originalLinks) ||
        !equal(saved.mentions, current.originalMentions))
    )
  }

  return {
    draft,
    attachedSkill,
    attachments,
    conversationID,
    selectedAgentUID,
    pending,
    liveStreams,
    /** The React key of an Agent's live reply in the timeline. */
    liveReplyKey(agentUID: string) {
      return liveReplyKey(agentUID)
    },
    /** The React key of a committed message: the key of the live reply that it replaced, or its own ID. */
    messageKey(messageID: string) {
      return replyKeys.value.committed[messageID] ?? messageID
    },
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
    editDraft,
    editLinks,
    editQuoted,
    hasEditText,
    backtrackMessageID,
    selectingMessages,
    selectedMessageIDs,
    selectedMessageCount,
    mentionedAgentUIDs,
    hasText,
    hasContent,
    followUpBehavior: followUpBehaviorPreference,
    setFollowUpBehavior(mode: FollowUpBehavior) {
      followUpBehaviorPreference.value = mode
      try {
        globalThis.localStorage?.setItem(FOLLOW_UP_BEHAVIOR_KEY, mode)
      } catch {
        // Ephemeral browser contexts keep the in-memory preference for this session.
      }
    },
    startSelectingMessages(initialMessageID?: string) {
      batch(() => {
        backtrackMessageID.value = undefined
        selectingMessages.value = true
        if (initialMessageID && !selectedMessageIDs.peek().includes(initialMessageID)) {
          selectedMessageIDs.value = [...selectedMessageIDs.peek(), initialMessageID]
        }
      })
    },
    toggleSelectedMessage(messageID: string) {
      const current = selectedMessageIDs.peek()
      selectedMessageIDs.value = current.includes(messageID)
        ? current.filter(id => id !== messageID)
        : [...current, messageID]
    },
    setSelectedMessages(ids: string[]) {
      selectedMessageIDs.value = [...new Set(ids)]
    },
    clearMessageSelection() {
      batch(() => {
        selectingMessages.value = false
        selectedMessageIDs.value = []
        backtrackMessageID.value = undefined
      })
    },
    startBacktrack(messageID: string) {
      backtrackMessageID.value = messageID
    },
    stepBacktrack(orderedIDs: string[], delta: -1 | 1): string | undefined {
      if (orderedIDs.length === 0) {
        backtrackMessageID.value = undefined
        return undefined
      }
      const currentID = backtrackMessageID.peek()
      const currentIndex = currentID ? orderedIDs.indexOf(currentID) : -1
      const nextIndex =
        currentIndex === -1 ? orderedIDs.length - 1 : Math.max(0, Math.min(orderedIDs.length - 1, currentIndex + delta))
      const nextID = orderedIDs[nextIndex]
      backtrackMessageID.value = nextID
      return nextID
    },
    clearBacktrack() {
      if (backtrackMessageID.peek() !== undefined) backtrackMessageID.value = undefined
    },
    startAnswer(interactionID: string, text = '') {
      if (editing.peek()?.kind === 'queue') return false
      batch(() => {
        backtrackMessageID.value = undefined
        if (text) appendDraft(text)
        answeringInteractionID.value = interactionID
      })
      return true
    },
    /** Adds the follow-up that a `ui` block suggests to the draft; the edit of a queued message keeps its own text. */
    suggestReply(text: string) {
      if (editing.peek()?.kind === 'queue') return false
      appendDraft(text)
      return true
    },
    cancelAnswer() {
      answeringInteractionID.value = undefined
    },
    /** Quote a message or a Page selection in the draft, in place of any passage it quoted before. */
    quote(link: { kind: 'message' | 'page'; id: string; quote: string }) {
      batch(() => {
        backtrackMessageID.value = undefined
        links.value = addLinks(links.peek(), [link], 'replace')
      })
    },
    referencePage(id: string) {
      links.value = addLinks(links.peek(), [{ kind: 'page', id }], 'keep')
    },
    referenceEditPage(id: string) {
      editLinks.value = addLinks(editLinks.peek(), [{ kind: 'page', id }], 'keep')
    },
    removeEditQuote() {
      editLinks.value = editLinks.peek().filter(link => link.quote == null)
    },
    rememberReading(presentation: ChatPresentation, position: ChatReadingPosition | undefined) {
      if (!gone.peek()) reading.value = { ...reading.peek(), [presentation]: position }
    },
    beginEdit(
      context: ChatEditSnapshot &
        Pick<ChatEditing, 'messageID' | 'queueVersion' | 'kind' | 'hasAttachments' | 'agentUID'>
    ) {
      const existing = editing.peek()
      if (existing) {
        if (existing.kind === 'queue' && context.kind === 'queue') return
        if (existing.kind === 'last' && context.kind === 'last' && existing.messageID === context.messageID) return
        cancelEdit()
      }
      const { messageID, text, queueVersion, kind, hasAttachments, agentUID } = context
      batch(() => {
        backtrackMessageID.value = undefined
        if (kind === 'last') {
          editing.value = {
            messageID,
            previousDraft: '',
            previousLinks: [],
            queueVersion,
            kind,
            originalText: text,
            originalLinks: context.links,
            originalMentions: context.mentions,
            hasAttachments,
            agentUID,
            commandID: uuidV4()
          }
          editDraft.value = text
          editLinks.value = context.links
        } else {
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
            agentUID
          }
          draft.value = text
          answeringInteractionID.value = undefined
          links.value = context.links
        }
      })
    },
    cancelEdit,
    savedEditChanged,
    restoreQueuedInput(input: ConversationPendingInput, agentUID: string) {
      const previous = draft.peek()
      const references = draftLinks(input.links)
      const people = input.mentions.flatMap(mention =>
        mention.type === 'human' && mention.displayName
          ? [{ type: 'human' as const, uid: mention.uid, displayName: mention.displayName }]
          : []
      )
      batch(() => {
        appendDraft(input.text)
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
      if (!useSaved && savedEditChanged(saved)) return false
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
          if (current.kind === 'last') {
            editDraft.value = saved.text
            editLinks.value = saved.links
          } else {
            draft.value = saved.text
            links.value = saved.links
          }
        }
      })
      return true
    },
    editSaved(messageID: string, text: string, savedLinks: ChatLinks = [], idleAgentUIDs: string[] = []) {
      const current = editing.peek()
      if (!current || current.messageID !== messageID) return false
      const currentDraft = current.kind === 'last' ? editDraft.peek() : draft.peek()
      const currentLinks = current.kind === 'last' ? editLinks.peek() : links.peek()
      if (currentDraft !== text || !equal(currentLinks, savedLinks)) return false
      batch(() => {
        if (current.kind === 'last') {
          const clearedUIDs = new Set([current.agentUID, ...idleAgentUIDs])
          const currentStreams = liveStreams.peek()
          if (Object.keys(currentStreams).some(uid => clearedUIDs.has(uid))) {
            const nextStreams = { ...currentStreams }
            for (const uid of clearedUIDs) delete nextStreams[uid]
            liveStreams.value = nextStreams
          }
          const currentActivities = activities.peek()
          let activitiesChanged = false
          const nextActivities = { ...currentActivities }
          for (const uid of clearedUIDs) {
            observedAt[uid] = ++activityObservation
            latestActivities.delete(uid)
            if (nextActivities[uid]?.state === 'active') {
              delete nextActivities[uid]
              activitiesChanged = true
            }
          }
          if (activitiesChanged) activities.value = nextActivities
        }
        cancelEdit()
      })
      return true
    },
    editCommand(): ConversationQueueRequest | undefined {
      const current = editing.value
      if (!current) return
      const currentDraft = current.kind === 'last' ? editDraft.value : draft.value
      const currentLinks = current.kind === 'last' ? editLinks.value : links.value
      return {
        action: current.kind === 'last' ? 'edit_last' : 'edit',
        agentUID: current.agentUID,
        messageID: current.messageID,
        text: currentDraft,
        links: currentLinks,
        mentions: current.originalMentions.filter(
          mention =>
            mention.type === 'agent' || !mention.displayName || hasDraftMention(currentDraft, mention.displayName)
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
    submit(
      conversationID: string | undefined,
      agentUID: string,
      nextID: () => string,
      deliveryMode: FollowUpBehavior = 'steer',
      resolvedTargetUID?: string
    ): MessageSubmission {
      const text = composeSkillSubmissionText(draft.value, attachedSkill.value)
      const previous = pending.value
      const capture = attachments.capture()
      const effectiveTarget = (resolvedTargetUID ?? targetAgentUID.value) || undefined
      const submission =
        previous &&
        previous.text === text &&
        previous.agentUID === agentUID &&
        previous.deliveryMode === deliveryMode &&
        previous.modelProfile === modelProfile.value &&
        previous.targetAgentUID === effectiveTarget &&
        equal(previous.mentions ?? [], mentions.value) &&
        equal(previous.links ?? [], links.value) &&
        equal(previous.attachmentIDs ?? [], capture.attachmentIDs)
          ? { ...previous, ...capture }
          : {
              conversationID: conversationID ?? nextID(),
              messageID: nextID(),
              agentUID,
              text,
              deliveryMode,
              modelProfile: modelProfile.value,
              targetAgentUID: effectiveTarget,
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
    resolvePendingAgent(messageID: string, uid: string) {
      if (pending.value?.messageID === messageID) pending.value = { ...pending.value, agentUID: uid }
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
    reconcile(
      messages: ConversationMessage[],
      pendingInteractions?: Pick<ConversationDetail['pendingInteractions'][number], 'interaction_id' | 'state'>[]
    ) {
      batch(() => {
        const current = pending.value
        if (current && messages.some(message => message.id === current.messageID)) {
          attachments.accepted(current.attachmentIDs)
          conversationID.value = current.conversationID
          pending.value = undefined
          clearCapturedDraft(current)
          error.value = undefined
        }
        if (pendingInteractions !== undefined) {
          const activeAnswerID = answeringInteractionID.peek()
          if (
            activeAnswerID &&
            !pendingInteractions.some(item => item.interaction_id === activeAnswerID && item.state === 'pending')
          ) {
            answeringInteractionID.value = undefined
          }
          const currentEdit = editing.peek()
          if (
            currentEdit?.previousAnsweringInteractionID &&
            !pendingInteractions.some(
              item => item.interaction_id === currentEdit.previousAnsweringInteractionID && item.state === 'pending'
            )
          ) {
            editing.value = { ...currentEdit, previousAnsweringInteractionID: undefined }
          }
        }
        const activeInlineEdit = editing.peek()
        if (activeInlineEdit?.kind === 'last' && !messages.some(message => message.id === activeInlineEdit.messageID)) {
          const modifiedText = editDraft.peek()
          const modifiedLinks = editLinks.peek()
          if (
            modifiedText.trim() !== '' &&
            (modifiedText !== activeInlineEdit.originalText || !equal(modifiedLinks, activeInlineEdit.originalLinks))
          ) {
            appendDraft(modifiedText)
            links.value = addLinks(links.peek(), modifiedLinks, 'keep')
          }
          cancelEdit()
        }
        const activeBacktrackID = backtrackMessageID.peek()
        if (activeBacktrackID && !messages.some(message => message.id === activeBacktrackID)) {
          backtrackMessageID.value = undefined
        }
        const currentSelected = selectedMessageIDs.peek()
        if (currentSelected.length > 0) {
          const loadedIDs = new Set(messages.map(message => message.id))
          if (currentSelected.some(id => !loadedIDs.has(id))) {
            selectedMessageIDs.value = currentSelected.filter(id => loadedIDs.has(id))
          }
        }
        const replaced = Object.values(liveStreams.peek()).flatMap(stream => {
          const reply = committedReply(messages, stream)
          return reply ? [{ stream, reply }] : []
        })
        if (replaced.length) {
          const keys = replyKeys.peek()
          const live = { ...keys.live }
          const committed = { ...keys.committed }
          for (const { stream, reply } of replaced) {
            committed[reply.id] ??= liveReplyKey(stream.agentUID, live)
            live[stream.agentUID] = (live[stream.agentUID] ?? 0) + 1
          }
          replyKeys.value = { live, committed }
          liveStreams.value = Object.fromEntries(
            Object.entries(liveStreams.peek()).filter(([, stream]) => !replaced.some(item => item.stream === stream))
          )
        }
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
        selectingMessages.value = false
        selectedMessageIDs.value = []
        backtrackMessageID.value = undefined
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
}

export const ChatModel = createModel(createChat)
