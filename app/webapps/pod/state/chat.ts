import { batch, computed, createModel, signal } from '@preact/signals-react'
import type {
  ConversationMessage,
  ConversationQueueRequest,
  ConversationStatus,
  MessageSubmission,
  PodActivity
} from '../api'
import { ChatAttachments } from './chat-attachments'
import { InternalAPIError } from '../../common/internal-api-client'
import { requestErrorCode } from '../../common/request-errors'

export type PendingMessage = MessageSubmission & { state: 'sending' | 'failed' }
export type LiveReply = { text: string; responseID: string; signalIDs: string[] }
export type FollowupMode = 'steer' | 'queue'
export type ChatPresentation = 'page' | 'standalone'
export type ChatReadingPosition = { atBottom: true } | { atBottom: false; messageID: string; offset: number }
export type DisplayMessage =
  | { type: 'committed'; message: ConversationMessage }
  | { type: 'pending'; message: PendingMessage }
  | { type: 'live'; text: string }

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
  live: LiveReply | undefined
): DisplayMessage[] {
  const result: DisplayMessage[] = committed.map(message => ({ type: 'committed', message }))
  if (pending && !committed.some(message => message.id === pending.messageID)) {
    result.push({ type: 'pending', message: pending })
  }
  if (live?.text && !replyCommitted(committed, live)) result.push({ type: 'live', text: live.text })
  return result
}

function replyCommitted(messages: ConversationMessage[], live: LiveReply): boolean {
  return messages.some(
    message =>
      message.signalID !== null &&
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
  const live = signal<LiveReply>()
  const activity = signal<PodActivity>()
  let latestActivity: PodActivity | undefined
  let activityObservation = 0
  const error = signal<unknown>()
  const connecting = signal(false)
  const gone = signal(false)
  const reading = signal<Partial<Record<ChatPresentation, ChatReadingPosition>>>({})
  const deliveryMode = signal<FollowupMode>('steer')
  const modelProfile = signal<string | null>(null)
  const editing = signal<{
    messageID: string
    previousDraft: string
    queueVersion: string
    kind: 'queue' | 'last'
    originalText: string | null
    hasAttachments: boolean
    commandID?: string
  }>()
  let stopCommandID: string | undefined
  const hasText = computed(() => draft.value.trim().length > 0)
  const hasContent = computed(() => hasText.value || attachments.hasFiles.value)

  return {
    draft,
    attachments,
    conversationID,
    selectedAgentUID,
    pending,
    live,
    activity,
    error,
    connecting,
    gone,
    reading,
    deliveryMode,
    modelProfile,
    editing,
    hasText,
    hasContent,
    rememberReading(presentation: ChatPresentation, position: ChatReadingPosition | undefined) {
      if (!gone.peek()) reading.value = { ...reading.peek(), [presentation]: position }
    },
    beginEdit(
      messageID: string,
      text: string | null,
      queueVersion: string,
      kind: 'queue' | 'last' = 'queue',
      hasAttachments = false
    ) {
      batch(() => {
        editing.value = {
          messageID,
          previousDraft: editing.value?.previousDraft ?? draft.value,
          queueVersion,
          kind,
          originalText: text,
          hasAttachments,
          ...(kind === 'last' ? { commandID: crypto.randomUUID() } : {})
        }
        draft.value = text ?? ''
      })
    },
    cancelEdit() {
      if (!editing.value) return
      batch(() => {
        draft.value = editing.value!.previousDraft
        editing.value = undefined
      })
    },
    rebaseEdit(messageID: string, savedText: string, queueVersion: string, useSaved = false) {
      const current = editing.peek()
      if (!current || current.messageID !== messageID) return false
      if (!useSaved && savedText !== (current.originalText ?? '')) return false
      batch(() => {
        editing.value = {
          ...current,
          queueVersion,
          originalText: savedText,
          ...(useSaved && current.kind === 'last' ? { commandID: crypto.randomUUID() } : {})
        }
        if (useSaved) draft.value = savedText
      })
      return true
    },
    editSaved(messageID: string, text: string) {
      if (editing.value?.messageID === messageID && draft.value === text) this.cancelEdit()
    },
    editCommand(): ConversationQueueRequest | undefined {
      const current = editing.value
      if (!current) return
      return {
        action: current.kind === 'last' ? 'edit_last' : 'edit',
        messageID: current.messageID,
        text: draft.value,
        expectedVersion: current.queueVersion,
        ...(current.kind === 'last' ? { expectedText: current.originalText, commandID: current.commandID } : {})
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
      mode = deliveryMode.value
    ): MessageSubmission {
      const text = draft.value
      const previous = pending.value
      const capture = attachments.capture()
      const submission =
        previous &&
        previous.text === text &&
        previous.agentUID === agentUID &&
        previous.deliveryMode === mode &&
        previous.modelProfile === modelProfile.value &&
        JSON.stringify(previous.attachmentIDs ?? []) === JSON.stringify(capture.attachmentIDs)
          ? { ...previous, ...capture }
          : {
              conversationID: conversationID ?? nextID(),
              messageID: nextID(),
              agentUID,
              text,
              deliveryMode: mode,
              modelProfile: modelProfile.value,
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
      if (failure instanceof InternalAPIError && requestErrorCode(failure.payload) === 'attachment_expired') {
        attachments.expired(pending.value.attachmentIDs)
      }
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
          if (draft.value === submission.text) draft.value = ''
          error.value = undefined
        }
      })
    },
    reconcile(messages: ConversationMessage[]) {
      batch(() => {
        const current = pending.value
        if (current && messages.some(message => message.id === current.messageID)) {
          attachments.accepted(current.attachmentIDs)
          conversationID.value = current.conversationID
          pending.value = undefined
          if (draft.value === current.text) draft.value = ''
          error.value = undefined
        }
        if (live.value && replyCommitted(messages, live.value)) live.value = undefined
      })
    },
    started(responseID: string, signalIDs: string[]) {
      if (gone.value) return
      live.value = { text: '', responseID, signalIDs }
    },
    delta(responseID: string, text: string, signalIDs: string[]) {
      if (gone.value || (live.value && live.value.responseID !== responseID)) return
      const current = live.value ?? { responseID, signalIDs, text: '' }
      live.value = { ...current, text: current.text + text }
    },
    reconcileStatus(responseID: string | undefined, status: ConversationStatus) {
      if (responseID && live.value?.responseID === responseID && status.state === 'idle') live.value = undefined
    },
    activityRead() {
      return activityObservation
    },
    observeActivity(incoming: PodActivity, readObservation?: number) {
      if (gone.value || (readObservation !== undefined && readObservation !== activityObservation)) return
      const current = latestActivity
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
      activityObservation++
      latestActivity = incoming
      activity.value = incoming.state === 'active' && !connecting.peek() ? incoming : undefined
    },
    markGone() {
      batch(() => {
        gone.value = true
        reading.value = {}
        live.value = undefined
        activity.value = undefined
        connecting.value = false
      })
    },
    disconnected() {
      if (gone.value) return
      activityObservation++
      batch(() => {
        live.value = undefined
        activity.value = undefined
        connecting.value = true
      })
    },
    connected() {
      connecting.value = false
    }
  }
})
