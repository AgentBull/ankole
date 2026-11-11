import { Button, InputGroup, InputGroupAddon, InputGroupTextarea, toast } from '@ankole/uikit'
import { useSignals } from '@preact/signals-react/runtime'
import { DismissRegular, MentionRegular, SpinnerIosRegular } from '@ankole/uikit/icons'
import { useEffect, useId, useLayoutEffect, useRef, useState } from 'react'
import { useTranslation } from 'react-i18next'
import { requestErrorMessage } from '../../common/request-errors'
import { chatError, type ConversationDetail, type ConversationMessage } from '../api'
import { MessageAttachments, chatAttachmentHandlers } from '../chat-attachments'
import { editingSnapshot, type ChatCommands } from '../chat-commands'
import { shouldSendOnEnter, type ChatModel } from '../state/chat'
import { DraftPageChip, removePageMention } from './composer'
import {
  completionAt,
  insertCompletionTrigger,
  type CompletionHandle,
  type ComposerCompletion
} from './composer-completion'
import { MentionPicker, type MentionChoice } from './mention-picker'

type Model = InstanceType<typeof ChatModel>

export function InlineMessageEditor({
  model,
  message,
  detail,
  canSubmit,
  recipientAvailable,
  submitting,
  editConflict,
  submitError,
  recovery,
  onSubmit,
  onCancel
}: {
  model: Model
  message: ConversationMessage
  detail: ConversationDetail
  canSubmit: boolean
  recipientAvailable: boolean
  submitting: boolean
  editConflict: boolean
  submitError?: unknown
  recovery: ChatCommands['recovery']
  onSubmit(): void
  onCancel(): void
}) {
  useSignals()
  const { t } = useTranslation()
  const shell = useRef<HTMLFormElement>(null)
  const textarea = useRef<HTMLTextAreaElement>(null)
  const pendingCaret = useRef<number>(undefined)
  const [picker, setPicker] = useState<ComposerCompletion>()
  const [pickerBelow, setPickerBelow] = useState(false)
  const pickerRef = useRef<ComposerCompletion>(undefined)
  const updatePicker = (next: ComposerCompletion | undefined) => {
    pickerRef.current = next
    setPicker(next)
  }
  const completion = useRef<CompletionHandle>(null)
  const completionID = useId()
  const inputID = useId()
  const hintID = useId()
  const composing = useRef(false)
  const lastCompositionEndAt = useRef<number | null>(null)

  const editing = model.editing.value
  const draft = model.editDraft.value
  const quoted = model.editQuoted.value
  const pageLinks = model.editLinks.value.filter(link => link.kind === 'page' && link.quote == null)
  const hasPicker = Boolean(picker)

  useLayoutEffect(() => {
    if (typeof CSS !== 'undefined' && CSS.supports('field-sizing', 'content')) return
    const input = textarea.current
    if (input) {
      input.style.height = 'auto'
      input.style.height = `${Math.min(input.scrollHeight, 240)}px`
    }
  }, [draft])

  useLayoutEffect(() => {
    const input = textarea.current
    if (!input) return
    input.focus({ preventScroll: true })
    const length = input.value.length
    input.setSelectionRange(length, length)
    shell.current?.scrollIntoView({ block: 'nearest' })
  }, [message.id])

  useLayoutEffect(() => {
    const cursor = pendingCaret.current
    if (cursor === undefined) return
    pendingCaret.current = undefined
    textarea.current?.focus()
    textarea.current?.setSelectionRange(cursor, cursor)
  }, [draft, picker])

  useLayoutEffect(() => {
    if (!hasPicker || !shell.current) return
    const scroller = shell.current.closest('.pod-chat-history-scroll')
    const shellRect = shell.current.getBoundingClientRect()
    const topBoundary = scroller ? scroller.getBoundingClientRect().top : 0
    setPickerBelow(shellRect.top - topBoundary < 260)
  }, [hasPicker])

  useEffect(() => {
    if (!picker) return
    const outside = (event: PointerEvent) => {
      if (!shell.current?.contains(event.target as Node)) updatePicker(undefined)
    }
    document.addEventListener('pointerdown', outside)
    return () => document.removeEventListener('pointerdown', outside)
  }, [picker])

  const syncPicker = (input: HTMLTextAreaElement) => {
    if (composing.current || submitting) return
    const active = pickerRef.current
    const next = completionAt(input.value, input.selectionStart, input.selectionEnd, active)
    if (next?.kind === 'slash') {
      updatePicker(undefined)
      return
    }
    updatePicker(next ? { ...next, kind: 'page' } : undefined)
  }

  const openPagePicker = () => {
    if (submitting) return
    const value = model.editDraft.value
    const start = textarea.current?.selectionStart ?? value.length
    const end = textarea.current?.selectionEnd ?? start
    const inserted = insertCompletionTrigger(value, start, end, 'page')
    pendingCaret.current = inserted.cursor
    model.editDraft.value = inserted.value
    updatePicker(inserted.completion)
  }

  const choosePage = (choice: MentionChoice) => {
    if (submitting || choice.type !== 'page') return
    const text = `@${choice.displayName}`
    const start = picker?.start ?? draft.length
    const end = picker?.end ?? start
    pendingCaret.current = start + text.length + 1
    model.editDraft.value = `${draft.slice(0, start)}${text} ${draft.slice(end)}`
    model.referenceEditPage(choice.uid)
    updatePicker(undefined)
    textarea.current?.focus()
  }

  const slot = editing ? detail.pendingQueues.find(queue => queue.agentUID === editing.agentUID) : undefined
  const stopsActiveTurn =
    !!editing &&
    ((!!slot && slot.workStatus.state !== 'idle') ||
      !!model.liveStreams.value[editing.agentUID] ||
      model.activities.value[editing.agentUID]?.state === 'active')
  const revertsLaterMessages = detail.messages.some(other => other.seq > message.seq)
  const keepsArtifacts = detail.artifacts.pageIDs.length > 0 || detail.linkedRuns.length > 0
  const hint = !recipientAvailable
    ? t('pod.chat_room.recipient_unavailable')
    : revertsLaterMessages
      ? t('pod.chat.edit_reverts_later')
      : stopsActiveTurn
        ? t('pod.chat.edit_stops_active')
        : keepsArtifacts
          ? t('pod.chat.retry_keeps_artifacts')
          : undefined

  const savedSnapshot = editing ? editingSnapshot(detail, editing) : undefined
  const savedChanged = !!savedSnapshot && model.savedEditChanged(savedSnapshot)
  const inlineFailure = submitError ?? recovery.error

  return (
    <form
      ref={shell}
      {...chatAttachmentHandlers(model.attachments, true, () =>
        toast.info(
          t('pod.chat.attachments_disabled_while_editing', {
            defaultValue: 'Finish or cancel editing before adding files.'
          })
        )
      )}
      data-inline-message-editor={message.id}
      data-picker-placement={picker && pickerBelow ? 'below' : undefined}
      className="pod-chat-inline-editor relative w-full max-w-[min(44rem,100%)] self-end"
      onSubmit={event => {
        event.preventDefault()
        if (canSubmit && !submitting) {
          updatePicker(undefined)
          onSubmit()
        }
      }}>
      {picker && (
        <MentionPicker
          detail={detail}
          pagesOnly
          allowAgents={false}
          query={picker.query}
          id={completionID}
          input={textarea}
          handle={completion}
          onChoose={choosePage}
          onClose={() => {
            updatePicker(undefined)
            textarea.current?.focus()
          }}
        />
      )}
      <label htmlFor={inputID} className="sr-only">
        {t('pod.chat.edit_message_label')}
      </label>
      <InputGroup variant="composer" className="pod-chat-composer-field">
        {editConflict && (
          <div role="alert" className="space-y-2 border-b border-border px-1 py-2 text-75 text-fg-secondary">
            <div className="flex flex-wrap items-center justify-between gap-2">
              <span>{t(savedChanged ? 'pod.chat.saved_message_changed' : 'pod.chat.errors.queue_changed')}</span>
              <div className="flex items-center gap-1.5">
                <Button
                  type="button"
                  size="xs"
                  variant="outline"
                  disabled={recovery.loading}
                  onClick={recovery.refresh}>
                  {t('pod.chat.refresh_edit')}
                </Button>
                {savedChanged && (
                  <Button
                    type="button"
                    size="xs"
                    variant="outline"
                    disabled={recovery.loading}
                    onClick={recovery.useSaved}>
                    {t('pod.chat.load_saved_message')}
                  </Button>
                )}
              </div>
            </div>
            {savedChanged && savedSnapshot && (
              <blockquote className="max-h-24 overflow-auto border-l-2 border-border pl-3 whitespace-pre-wrap break-words">
                {savedSnapshot.text}
              </blockquote>
            )}
          </div>
        )}
        {inlineFailure != null && (
          <div role="alert" className="border-b border-border px-1 py-2 text-75 text-destructive-foreground">
            {requestErrorMessage(chatError(inlineFailure))}
          </div>
        )}
        {quoted && (
          <div className="pod-chat-quoted">
            <blockquote>{quoted.quote}</blockquote>
            <Button
              type="button"
              size="icon-xs"
              variant="ghost"
              disabled={submitting}
              aria-label={t('common.close')}
              onClick={() => model.removeEditQuote()}>
              <DismissRegular aria-hidden />
            </Button>
          </div>
        )}
        {message.attachments.length > 0 && (
          <MessageAttachments
            conversationID={detail.conversation.id}
            messageID={message.id}
            attachments={message.attachments}
          />
        )}
        {pageLinks.length > 0 && (
          <div className="pod-chat-draft-pages">
            {pageLinks.map(link => (
              <DraftPageChip
                key={link.id}
                id={link.id}
                onRemove={name => {
                  if (submitting) return
                  model.editLinks.value = model.editLinks.value.filter(item => item !== link)
                  if (name) model.editDraft.value = removePageMention(model.editDraft.value, name)
                }}
              />
            ))}
          </div>
        )}
        {hint && (
          <p id={hintID} className="px-1 pt-1 text-50 text-fg-tertiary">
            {hint}
          </p>
        )}
        <div className="pod-chat-composer-editor">
          <InputGroupTextarea
            ref={textarea}
            id={inputID}
            name="editedMessage"
            readOnly={submitting}
            aria-busy={submitting || undefined}
            aria-describedby={hint ? hintID : undefined}
            aria-autocomplete="list"
            aria-haspopup="listbox"
            aria-controls={picker ? completionID : undefined}
            className="pod-chat-composer-input w-full min-h-[2.5rem] max-h-60 resize-none [field-sizing:content]"
            rows={2}
            value={draft}
            onChange={event => {
              if (submitting) return
              if (!composing.current) lastCompositionEndAt.current = null
              model.editDraft.value = event.target.value
              syncPicker(event.target)
            }}
            onSelect={event => syncPicker(event.currentTarget)}
            onCompositionStart={() => {
              composing.current = true
              updatePicker(undefined)
            }}
            onCompositionEnd={event => {
              composing.current = false
              lastCompositionEndAt.current = event.nativeEvent.timeStamp
              syncPicker(event.currentTarget)
            }}
            onBlur={() => {
              if (composing.current) composing.current = false
              lastCompositionEndAt.current = null
            }}
            onKeyDown={event => {
              if (composing.current || event.nativeEvent.isComposing || event.nativeEvent.keyCode === 229) return
              if (picker && completion.current?.onKeyDown(event)) return
              const justEndedComposition =
                lastCompositionEndAt.current !== null &&
                Math.abs(event.nativeEvent.timeStamp - lastCompositionEndAt.current) < 50
              if (event.key === 'Escape') {
                event.preventDefault()
                event.stopPropagation()
                if (!justEndedComposition && !submitting) onCancel()
                return
              }
              if (
                shouldSendOnEnter({
                  key: event.key,
                  shiftKey: event.shiftKey,
                  ctrlKey: event.ctrlKey,
                  metaKey: event.metaKey,
                  isComposing: event.nativeEvent.isComposing,
                  keyCode: event.nativeEvent.isComposing ? 229 : event.nativeEvent.keyCode
                })
              ) {
                event.preventDefault()
                if (!event.ctrlKey && !event.metaKey && justEndedComposition) {
                  return
                }
                if (canSubmit && !submitting) {
                  updatePicker(undefined)
                  onSubmit()
                }
              }
            }}
          />
        </div>
        <InputGroupAddon align="block-end" className="pod-chat-composer-tools flex-wrap gap-2">
          <div className="flex min-w-0 flex-1 items-center gap-1.5">
            <Button
              type="button"
              size="icon-sm"
              variant="ghost"
              disabled={submitting}
              aria-label={t('pod.chat_room.mention')}
              onClick={openPagePicker}>
              <MentionRegular aria-hidden />
            </Button>
          </div>
          <div className="flex shrink-0 items-center gap-1.5">
            <Button type="button" size="sm" variant="ghost" disabled={submitting} onClick={onCancel}>
              {t('pod.chat.edit_cancel')}
            </Button>
            <Button type="submit" size="sm" variant="default" disabled={!canSubmit || submitting}>
              {submitting && <SpinnerIosRegular className="size-3.5 animate-spin" aria-hidden />}
              {t('pod.chat.edit_send')}
            </Button>
          </div>
        </InputGroupAddon>
      </InputGroup>
    </form>
  )
}
