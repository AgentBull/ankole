import { useQuery } from '@tanstack/react-query'
import { useEffect, useRef, useState } from 'react'
import { useTranslation } from 'react-i18next'
import { podKeys, type ConversationDetail } from '../api'
import { podReplySuggestion } from '../api/generated/sdk.gen'
import { isLiveExecutionStatus } from './execution-status'
import type { TimelineMessage } from './types'

// A suggestion stops for the rest of the visit once the Human passes over this many in a row.
const IGNORED_LIMIT = 3

const ACTIVE_ROW_STATUSES = new Set(['waiting_choice', 'streaming', 'queued', 'running_background'])

interface ActiveReplySuggestion {
  text: string
  accept(): void
}

/**
 * The latest message that may receive a reply suggestion: an Agent reply in a room whose only
 * human participant is the viewer, with no question, confirmation card, queued input, or running
 * work (including background jobs, workflows, and delegated colleague tasks) still active.
 */
export function replySuggestionTarget(
  detail: Pick<ConversationDetail, 'messages' | 'pendingInteractions' | 'pendingQueues'> & {
    linkedRuns?: Pick<ConversationDetail['linkedRuns'][number], 'status'>[]
    conversation: Pick<ConversationDetail['conversation'], 'participants'> & {
      rowStatus?: ConversationDetail['conversation']['rowStatus']
    }
  }
) {
  const latest = detail.messages.at(-1)
  const humans = detail.conversation.participants.filter(member => member.type === 'human')
  if (humans.length !== 1 || latest?.authorType !== 'agent' || latest.kind !== 'message') return undefined
  if (detail.pendingInteractions.length) return undefined
  if (detail.pendingQueues.some(queue => queue.inputs.length || queue.workStatus.state !== 'idle')) return undefined
  if (detail.linkedRuns?.some(run => isLiveExecutionStatus(run.status))) return undefined
  if (detail.conversation.rowStatus && ACTIVE_ROW_STATUSES.has(detail.conversation.rowStatus)) return undefined
  if (
    detail.messages.some(message => {
      const card = (message as TimelineMessage).richContent?.action_card
      return card != null && (card.status ?? 'prepared') === 'prepared'
    })
  ) {
    return undefined
  }
  return latest.id
}

/** Resolve one inline next-message suggestion for an idle, empty composer. */
export function useReplySuggestion({
  conversationID,
  detail,
  idle,
  onUse
}: {
  conversationID: string | undefined
  detail: ConversationDetail | undefined
  /** The composer is empty and no work is running, so a suggestion would not interrupt. */
  idle: boolean
  onUse(text: string): void
}): ActiveReplySuggestion | undefined {
  const { i18n } = useTranslation()
  const [ignored, setIgnored] = useState(0)
  const shown = useRef<{ conversationID: string; messageID: string } | undefined>(undefined)
  const passed = useRef(new Set<string>())
  useEffect(() => {
    shown.current = undefined
    passed.current.clear()
    setIgnored(0)
  }, [conversationID])
  const target = conversationID && detail && idle && ignored < IGNORED_LIMIT ? replySuggestionTarget(detail) : undefined
  const suggestion = useQuery({
    queryKey: podKeys.replySuggestion(conversationID ?? '', target ?? ''),
    queryFn: () => podReplySuggestion({ path: { id: conversationID! }, body: { data: { locale: i18n.language } } }),
    enabled: !!conversationID && !!target,
    staleTime: Infinity,
    retry: false,
    refetchOnWindowFocus: false
  })
  const text = target && suggestion.data?.messageID === target ? suggestion.data.text : undefined
  // A suggestion counts once as passed over when typing or a new turn hides it before the Human uses it.
  useEffect(() => {
    if (conversationID && target && text) {
      shown.current = { conversationID, messageID: target }
      return
    }
    const previous = shown.current
    if (!previous) return
    shown.current = undefined
    if (previous.conversationID === conversationID && !passed.current.has(previous.messageID)) {
      passed.current.add(previous.messageID)
      setIgnored(count => count + 1)
    }
  }, [conversationID, target, text])
  if (!text) return undefined
  return {
    text,
    accept: () => {
      shown.current = undefined
      setIgnored(0)
      onUse(text)
    }
  }
}

/** Inline ghost placeholder and trailing Tab keycap inside an empty composer input. */
export function ReplySuggestionGhost({ suggestion }: { suggestion: ActiveReplySuggestion | undefined }) {
  const { t } = useTranslation()
  if (!suggestion) return null
  return (
    <div className="pod-chat-composer-suggestion">
      <span aria-hidden className="pod-chat-composer-suggestion-text">
        {suggestion.text}
      </span>
      <button
        type="button"
        tabIndex={-1}
        className="pod-chat-composer-suggestion-accept"
        aria-label={`Tab — ${t('pod.reply_suggestion.use', { text: suggestion.text })}`}
        title={t('pod.reply_suggestion.tab_hint')}
        onMouseDown={event => event.preventDefault()}
        onClick={suggestion.accept}>
        <kbd className="pod-chat-composer-suggestion-kbd">
          <span aria-hidden className="pod-chat-composer-suggestion-glyph">
            ⇥
          </span>
          Tab
        </kbd>
      </button>
    </div>
  )
}
