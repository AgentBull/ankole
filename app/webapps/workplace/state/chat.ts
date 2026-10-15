import { batch, computed, createModel, signal } from '@preact/signals-react'
import type { ConversationMessage, ConversationStatus, MessageSubmission } from '../api'

export type PendingMessage = MessageSubmission & { state: 'sending' | 'failed' }
export type LiveReply = { text: string; responseID: string; signalIDs: string[] }
export type DisplayMessage =
  | { type: 'committed'; message: ConversationMessage }
  | { type: 'pending'; message: PendingMessage }
  | { type: 'live'; text: string }

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
}): boolean {
  return event.key === 'Enter' && !event.shiftKey && !event.isComposing && event.keyCode !== 229
}

export const ChatModel = createModel(() => {
  const draft = signal('')
  const selectedAgentUID = signal('')
  const pending = signal<PendingMessage>()
  const live = signal<LiveReply>()
  const error = signal<unknown>()
  const connecting = signal(false)
  const gone = signal(false)
  const hasText = computed(() => draft.value.trim().length > 0)

  return {
    draft,
    selectedAgentUID,
    pending,
    live,
    error,
    connecting,
    gone,
    hasText,
    submit(conversationID: string | undefined, agentUID: string, nextID: () => string): MessageSubmission {
      const text = draft.value
      const previous = pending.value
      const submission =
        previous && previous.text === text && previous.agentUID === agentUID
          ? previous
          : { conversationID: conversationID ?? nextID(), messageID: nextID(), agentUID, text }
      batch(() => {
        pending.value = { ...submission, state: 'sending' }
        error.value = undefined
      })
      return submission
    },
    failed(failure: unknown) {
      // A committed message may arrive through SSE before the POST fails.
      if (!pending.value) return
      batch(() => {
        pending.value = { ...pending.value!, state: 'failed' }
        error.value = failure
      })
    },
    accepted(submission: MessageSubmission) {
      batch(() => {
        if (pending.value?.messageID === submission.messageID) pending.value = undefined
        if (draft.value === submission.text) draft.value = ''
        error.value = undefined
      })
    },
    reconcile(messages: ConversationMessage[]) {
      batch(() => {
        const current = pending.value
        if (current && messages.some(message => message.id === current.messageID)) {
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
    markGone() {
      batch(() => {
        gone.value = true
        live.value = undefined
        connecting.value = false
      })
    },
    disconnected() {
      if (gone.value) return
      batch(() => {
        live.value = undefined
        connecting.value = true
      })
    },
    connected() {
      connecting.value = false
    }
  }
})
