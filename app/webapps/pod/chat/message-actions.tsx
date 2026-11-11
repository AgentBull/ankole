import { useCopyFeedback } from '@ankole/uikit/hooks/use-copy-feedback'
import { Button, CopyIcon, toast, useReducedMotion } from '@ankole/uikit'
import {
  ArrowCounterclockwiseRegular,
  CheckmarkCircleRegular,
  EditRegular,
  FlashRegular,
  TextQuoteRegular
} from '@ankole/uikit/icons'
import { useTranslation } from 'react-i18next'
import { messageTime } from './timeline-projections'

const actionButton = 'motion-safe:active:scale-none!'
const actionIcon =
  'motion-safe:[transition:transform_160ms_cubic-bezier(.32,.72,.24,1)] motion-safe:group-active/button:transform-[scale(.9)] motion-reduce:transition-none'

/**
 * The actions of a message and the time it was sent: select, quote, copy, then save as Skill, edit, and retry when
 * they apply, as 32px buttons 6px apart. The time sits on the inner side of the row: after the actions under a
 * message on the left, and before them (`timeFirst`) under the reader's own message on the right. The row always
 * takes its place under the message, so showing it never moves the timeline: the latest reply shows it, and an
 * earlier message shows it while the pointer or keyboard focus is on that message.
 */
export function MessageActions({
  text,
  time,
  timeFirst = false,
  onQuote,
  onSaveAsSkill,
  onSelectMessage,
  onEdit,
  editDisabledReason,
  onRetry,
  alwaysVisible = false
}: {
  text: string
  /** When the message was sent. */
  time?: string
  /** States the time before the actions instead of after them. */
  timeFirst?: boolean
  onQuote?: (text: string) => void
  onSaveAsSkill?: () => void
  onSelectMessage?: () => void
  onEdit?: () => void
  editDisabledReason?: string
  onRetry?: () => void
  alwaysVisible?: boolean
}) {
  const { t, i18n } = useTranslation()
  const [copied, markCopied] = useCopyFeedback(false, 1600)
  const reducedMotion = useReducedMotion()
  const sentAt = time && (
    <time className="pod-chat-message-time" dateTime={time} title={new Date(time).toLocaleString(i18n.language)}>
      {messageTime(time, i18n.language)}
    </time>
  )
  return (
    <div
      className="pod-chat-message-actions motion-safe:[transition:opacity_240ms_ease] motion-reduce:transition-none"
      data-visible={alwaysVisible || !!onRetry || undefined}
      role="group"
      aria-label={t('pod.chat_timeline.message_actions')}>
      {timeFirst && sentAt}
      {onSelectMessage && (
        <Button
          variant="ghost"
          size="icon-md"
          className={actionButton}
          title={t('pod.chat_timeline.select_messages', { defaultValue: 'Select messages' })}
          aria-label={t('pod.chat_timeline.select_messages', { defaultValue: 'Select messages' })}
          onClick={onSelectMessage}>
          <CheckmarkCircleRegular aria-hidden className={actionIcon} />
        </Button>
      )}
      {onQuote && !!text && (
        <Button
          variant="ghost"
          size="icon-md"
          className={actionButton}
          title={t('pod.chat_timeline.quote_reply')}
          aria-label={t('pod.chat_timeline.quote_reply')}
          onClick={event => {
            const selection = window.getSelection()
            const message = event.currentTarget.closest('article')
            const selected =
              selection && message?.contains(selection.anchorNode) && message.contains(selection.focusNode)
                ? selection.toString()
                : ''
            onQuote(selected.trim() ? selected : text)
          }}>
          <TextQuoteRegular aria-hidden className={actionIcon} />
        </Button>
      )}
      {!!text && (
        <Button
          variant="ghost"
          size="icon-md"
          className={actionButton}
          title={t(copied ? 'pod.chat.message_copied' : 'pod.chat.copy_message')}
          aria-label={t(copied ? 'pod.chat.message_copied' : 'pod.chat.copy_message')}
          onClick={async () => {
            try {
              await navigator.clipboard.writeText(text)
              markCopied(true)
            } catch {
              toast.error(t('pod.chat.copy_failed'))
            }
          }}>
          <CopyIcon copied={copied} className={`size-5 ${actionIcon}`} />
        </Button>
      )}
      {onSaveAsSkill && !!text && (
        <Button
          variant="ghost"
          size="icon-md"
          className={actionButton}
          title={t('pod.chat_timeline.save_as_skill', { defaultValue: 'Save as Skill (/learn)' })}
          aria-label={t('pod.chat_timeline.save_as_skill', { defaultValue: 'Save as Skill (/learn)' })}
          onClick={onSaveAsSkill}>
          <FlashRegular aria-hidden className={actionIcon} />
        </Button>
      )}
      {onEdit && (
        <Button
          variant="ghost"
          size="icon-md"
          title={`${editDisabledReason || t('pod.chat.edit_last')} · ${t('pod.chat.retry_keeps_artifacts')}`}
          aria-label={t('pod.chat.edit_last')}
          aria-description={editDisabledReason}
          disabled={!!editDisabledReason}
          focusableWhenDisabled
          className={`${actionButton} ${editDisabledReason ? 'opacity-45' : ''}`}
          onClick={onEdit}>
          <EditRegular aria-hidden className={actionIcon} />
        </Button>
      )}
      {onRetry && (
        <Button
          variant="ghost"
          size="xs"
          className={actionButton}
          title={t('pod.chat.retry_keeps_artifacts')}
          onClick={event => {
            if (!reducedMotion) {
              event.currentTarget.querySelector('svg')?.animate([{ rotate: '0deg' }, { rotate: '360deg' }], {
                duration: 640,
                easing: 'cubic-bezier(.32,.72,.24,1)'
              })
            }
            onRetry()
          }}>
          <ArrowCounterclockwiseRegular aria-hidden className={actionIcon} />
          {t('pod.chat.retry_reply')}
        </Button>
      )}
      {!timeFirst && sentAt}
    </div>
  )
}
