import { useCopyFeedback } from '@ankole/uikit/hooks/use-copy-feedback'
import { Button, toast, useReducedMotion } from '@ankole/uikit'
import { RiCheckboxMultipleLine, RiDoubleQuotesL, RiEditLine, RiFileCopyLine, RiRestartLine } from '@remixicon/react'
import { useTranslation } from 'react-i18next'

const actionButton = 'motion-safe:active:scale-none!'
const actionIcon =
  'motion-safe:[transition:transform_160ms_cubic-bezier(.32,.72,.24,1)] motion-safe:group-active/button:transform-[scale(.9)] motion-reduce:transition-none'
const copyLayer =
  '[grid-area:1/1] opacity-0 data-visible:opacity-100 motion-safe:transform-[scale(.6)] motion-safe:blur-[2px] motion-safe:data-visible:transform-none motion-safe:data-visible:blur-none motion-safe:[transition:opacity_200ms_ease,transform_300ms_cubic-bezier(.32,.72,.24,1),filter_200ms_ease] motion-reduce:transition-none'

export function MessageActions({
  text,
  onQuote,
  onSelectMessage,
  onEdit,
  editDisabledReason,
  onRetry,
  alwaysVisible = false
}: {
  text: string
  onQuote?: (text: string) => void
  onSelectMessage?: () => void
  onEdit?: () => void
  editDisabledReason?: string
  onRetry?: () => void
  alwaysVisible?: boolean
}) {
  const { t } = useTranslation()
  const [copied, markCopied] = useCopyFeedback(false, 1600)
  const reducedMotion = useReducedMotion()
  return (
    <div
      className="pod-chat-message-actions motion-safe:[transition:opacity_240ms_ease] motion-reduce:transition-none"
      data-visible={alwaysVisible || !!onRetry || undefined}
      role="group"
      aria-label={t('pod.chat_timeline.message_actions')}>
      {!!text && (
        <Button
          variant="ghost"
          size="icon-xs"
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
          <span aria-hidden className={`grid size-3.5 place-items-center ${actionIcon}`}>
            <RiFileCopyLine data-visible={!copied || undefined} className={copyLayer} />
            <svg
              viewBox="0 0 24 24"
              fill="none"
              stroke="currentColor"
              strokeWidth="2.6"
              strokeLinecap="round"
              strokeLinejoin="round"
              data-visible={copied || undefined}
              className={copyLayer}>
              <path
                d="M5 12l4 4L19 6"
                pathLength={1}
                strokeDasharray={1}
                strokeDashoffset={copied ? 0 : 1}
                className={`motion-reduce:transition-none ${
                  copied ? 'motion-safe:[transition:stroke-dashoffset_340ms_cubic-bezier(.32,.72,.24,1)_60ms]' : ''
                }`}
              />
            </svg>
          </span>
        </Button>
      )}
      {onQuote && !!text && (
        <Button
          variant="ghost"
          size="icon-xs"
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
          <RiDoubleQuotesL aria-hidden className={actionIcon} />
        </Button>
      )}
      {onSelectMessage && (
        <Button
          variant="ghost"
          size="icon-xs"
          className={actionButton}
          title={t('pod.chat_timeline.select_messages', { defaultValue: 'Select messages' })}
          aria-label={t('pod.chat_timeline.select_messages', { defaultValue: 'Select messages' })}
          onClick={onSelectMessage}>
          <RiCheckboxMultipleLine aria-hidden className={actionIcon} />
        </Button>
      )}
      {onEdit && (
        <Button
          variant="ghost"
          size="icon-xs"
          title={`${editDisabledReason || t('pod.chat.edit_last')} · ${t('pod.chat.retry_keeps_artifacts')}`}
          aria-label={t('pod.chat.edit_last')}
          aria-description={editDisabledReason}
          disabled={!!editDisabledReason}
          focusableWhenDisabled
          className={`${actionButton} ${editDisabledReason ? 'opacity-45' : ''}`}
          onClick={onEdit}>
          <RiEditLine aria-hidden className={actionIcon} />
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
          <RiRestartLine aria-hidden className={actionIcon} />
          {t('pod.chat.retry_reply')}
        </Button>
      )}
    </div>
  )
}
