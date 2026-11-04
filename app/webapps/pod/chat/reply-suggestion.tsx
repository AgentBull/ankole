import { Button } from '@ankole/uikit'
import { RiSparkling2Line } from '@remixicon/react'
import { useQuery } from '@tanstack/react-query'
import { useEffect, useRef, useState } from 'react'
import { useTranslation } from 'react-i18next'
import { podKeys, type ConversationDetail } from '../api'
import { podReplySuggestion } from '../api/generated/sdk.gen'

// A suggestion stops for the rest of the visit once the Human passes over this many in a row.
const IGNORED_LIMIT = 3

/**
 * The latest message that may receive a reply suggestion: an Agent reply in a room whose only
 * human participant is the viewer, with no question, queued input, or running work after it.
 */
export function replySuggestionTarget(
  detail: Pick<ConversationDetail, 'messages' | 'pendingInteractions' | 'pendingQueues'> & {
    conversation: Pick<ConversationDetail['conversation'], 'participants'>
  }
) {
  const latest = detail.messages.at(-1)
  const humans = detail.conversation.participants.filter(member => member.type === 'human')
  if (humans.length !== 1 || latest?.authorType !== 'agent' || latest.kind !== 'message') return undefined
  if (detail.pendingInteractions.length) return undefined
  if (detail.pendingQueues.some(queue => queue.inputs.length || queue.workStatus.state !== 'idle')) return undefined
  return latest.id
}

/** One line the Human may send next; choosing it only fills the draft. */
export function ReplySuggestion({
  conversationID,
  detail,
  idle,
  onUse
}: {
  conversationID: string
  detail: ConversationDetail
  /** The composer is empty and no work is running, so a suggestion would not interrupt. */
  idle: boolean
  onUse(text: string): void
}) {
  const { t, i18n } = useTranslation()
  const [ignored, setIgnored] = useState(0)
  const shown = useRef<string | undefined>(undefined)
  const passed = useRef(new Set<string>())
  const target = idle && ignored < IGNORED_LIMIT ? replySuggestionTarget(detail) : undefined
  const suggestion = useQuery({
    queryKey: podKeys.replySuggestion(conversationID, target ?? ''),
    queryFn: () => podReplySuggestion({ path: { id: conversationID }, body: { data: { locale: i18n.language } } }),
    enabled: !!target,
    staleTime: Infinity,
    retry: false,
    refetchOnWindowFocus: false
  })
  const text = target && suggestion.data?.messageID === target ? suggestion.data.text : undefined
  // A suggestion counts once as passed over when typing or a new turn hides it before the Human uses it.
  useEffect(() => {
    if (text) shown.current = target
    else if (shown.current) {
      if (!passed.current.has(shown.current)) {
        passed.current.add(shown.current)
        setIgnored(count => count + 1)
      }
      shown.current = undefined
    }
  }, [text, target])
  if (!text) return null
  return (
    <div className="pod-chat-reply-suggestion">
      <Button
        size="xs"
        variant="outline"
        aria-label={t('pod.reply_suggestion.use', { text })}
        onClick={() => {
          shown.current = undefined
          setIgnored(0)
          onUse(text)
        }}>
        <RiSparkling2Line aria-hidden />
        <span className="truncate">{text}</span>
      </Button>
    </div>
  )
}
