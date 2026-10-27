import { Button, cn } from '@ankole/uikit'
import { RiCheckLine, RiQuestionLine } from '@remixicon/react'
import { useMutationState } from '@tanstack/react-query'
import { useEffect, useRef, useState } from 'react'
import { useTranslation } from 'react-i18next'
import { requestErrorCode } from '../../common/request-errors'
import type { ChatInteraction, ClarifyPrompt } from './types'
import type { InteractionAnswer } from './room-api'

export type ClarifyAnswer = InteractionAnswer

export function ChoiceCard({
  prompt,
  interaction,
  onAnswer,
  onComposeAnswer,
  readOnlyReason,
  keyboardActive = false
}: {
  prompt: ClarifyPrompt
  interaction: ChatInteraction
  onAnswer?: (interactionID: string, answer: ClarifyAnswer) => Promise<unknown>
  onComposeAnswer?: (interactionID: string, text: string) => void
  readOnlyReason?: string
  keyboardActive?: boolean
}) {
  const { t } = useTranslation()
  const [text, setText] = useState('')
  const card = useRef<HTMLDivElement>(null)
  const submitting = useRef(false)
  const result = useMutationState({
    filters: {
      predicate: mutation =>
        (mutation.state.variables as { interactionID?: string } | undefined)?.interactionID === prompt.interaction_id
    },
    select: mutation => mutation.state
  }).at(-1)
  const pending = result?.status === 'pending'
  const decidedElsewhere = requestErrorCode(result?.error) === 'interaction_not_pending'
  const enabled =
    interaction.state === 'pending' && !!onAnswer && !pending && result?.status !== 'success' && !decidedElsewhere
  const answer = (value: ClarifyAnswer) => {
    if (!enabled || submitting.current) return
    submitting.current = true
    void onAnswer!(prompt.interaction_id, value)
      .catch(() => {})
      .finally(() => {
        submitting.current = false
      })
  }
  const choices = prompt.choices
  const answerLabel = choices.find(choice => choice.id === interaction.choice_id)?.label || interaction.answer_text
  useEffect(() => {
    if (!enabled || !keyboardActive) return
    const keydown = (event: KeyboardEvent) => {
      if (event.ctrlKey || event.altKey || event.metaKey || event.shiftKey || event.isComposing || event.repeat) return
      if (
        (event.target as HTMLElement)?.closest(
          'input,textarea,select,button,[contenteditable="true"],[role="textbox"],[role="dialog"],[role="menu"],[role="listbox"]'
        )
      ) {
        return
      }
      const index = ['1', '2', '3', '4'].indexOf(event.key)
      const choice = choices[index]
      if (!choice || !card.current?.getClientRects().length) return
      event.preventDefault()
      answer({ choiceID: choice.id })
    }
    document.addEventListener('keydown', keydown)
    return () => document.removeEventListener('keydown', keydown)
  }, [enabled, keyboardActive, choices, onAnswer])
  return (
    <div
      ref={card}
      className={cn('pod-chat-choice-card', interaction.state === 'superseded' && 'pod-chat-choice-superseded')}
      data-state={interaction.state}>
      <div className="pod-chat-choice-header">
        <RiQuestionLine aria-hidden />
        <span>{t('pod.chat_timeline.decision_needed')}</span>
      </div>
      <p className="pod-chat-choice-question">{prompt.question}</p>
      <div className="pod-chat-choices">
        {choices.map((choice, index) => {
          const shortcut = enabled && keyboardActive && index < 4 ? String(index + 1) : undefined
          return (
            <Button
              key={choice.id}
              variant="outline"
              className="pod-chat-choice"
              disabled={!enabled}
              aria-keyshortcuts={shortcut}
              aria-pressed={interaction.choice_id === choice.id}
              onClick={() => answer({ choiceID: choice.id })}>
              <span>
                <strong>{choice.label}</strong>
                {choice.description && <small>{choice.description}</small>}
              </span>
              {shortcut && <kbd>{shortcut}</kbd>}
            </Button>
          )
        })}
      </div>
      {interaction.state === 'pending' && prompt.allow_free_text && (
        <form
          className="pod-chat-choice-custom"
          onSubmit={event => {
            event.preventDefault()
            if (enabled && text.trim()) answer({ text: text.trim() })
          }}>
          <input
            aria-label={t('pod.chat_timeline.custom_answer')}
            placeholder={t('pod.chat_timeline.something_else')}
            value={text}
            disabled={!enabled}
            onChange={event => setText(event.currentTarget.value)}
          />
          <Button type="submit" size="xs" variant="ghost" disabled={!enabled || !text.trim()}>
            {t('pod.chat_timeline.answer')}
          </Button>
        </form>
      )}
      {interaction.state === 'answered' && (
        <p className="pod-chat-choice-outcome">
          <RiCheckLine aria-hidden />
          <span className="pod-chat-event-avatar" aria-hidden>
            {Array.from(interaction.answered_by_name || t('pod.chat_timeline.teammate'))[0]}
          </span>
          <span>
            {t('pod.chat_timeline.answered_by', {
              name: interaction.answered_by_name || t('pod.chat_timeline.teammate')
            })}
            {answerLabel && <> · {answerLabel}</>}
          </span>
        </p>
      )}
      {interaction.state === 'pending' && prompt.allow_free_text && onComposeAnswer && (
        <div className="pod-chat-choice-compose">
          <Button
            size="xs"
            variant="ghost"
            disabled={!enabled}
            onClick={() => {
              onComposeAnswer(prompt.interaction_id, text)
              setText('')
            }}>
            {t('pod.chat_timeline.compose_answer')}
          </Button>
        </div>
      )}
      {interaction.state === 'superseded' && (
        <p className="pod-chat-choice-outcome">{t('pod.chat_timeline.superseded')}</p>
      )}
      {interaction.state === 'pending' && decidedElsewhere && (
        <p role="status" className="pod-chat-choice-outcome">
          {t('pod.chat.errors.interaction_not_pending')}
        </p>
      )}
      {pending && (
        <p role="status" className="pod-chat-choice-outcome">
          {t('pod.chat_timeline.submitting_answer')}
        </p>
      )}
      {interaction.state === 'pending' && !onAnswer && readOnlyReason && (
        <p className="pod-chat-choice-outcome">{readOnlyReason}</p>
      )}
    </div>
  )
}
