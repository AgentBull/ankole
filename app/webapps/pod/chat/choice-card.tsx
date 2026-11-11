import { createStateStore, type Spec } from '@json-render/react'
import { useMutationState } from '@tanstack/react-query'
import { useContext, useEffect, useRef, useState } from 'react'
import { useTranslation } from 'react-i18next'
import { requestErrorCode, requestErrorDetails } from '../../common/request-errors'
import { collect, initialDraft } from './clarify-form'
import { InteractionSurface, interactionSpec } from './interaction-surface'
import { RevealInTimeline } from './timeline-scroll'
import type { ChatInteraction, ClarifyField, ClarifyPrompt } from './types'
import type { InteractionAnswer } from './room-api'

export type ClarifyAnswer = InteractionAnswer

type ClarifyView = {
  prompt: ClarifyPrompt
  interaction: ChatInteraction
  /** Names a colleague who asks from a delegated exchange, so the header says who waits for the answer. */
  askedBy?: string
  /** The viewer may answer now: the question is pending, they may invoke its Agent, and no answer is in flight. */
  enabled: boolean
  submitting: boolean
  decidedElsewhere: boolean
  /** The field error codes of the submission that the control plane rejected last. */
  rejection?: { at: number; fields: Record<string, string> }
  canCompose: boolean
  shortcuts: boolean
  readOnlyReason?: string
}

/**
 * Builds the Clarify card as an interaction spec from the question that the control plane committed and the
 * state of its checkpoint. The draft lives in the card's state: `/text` for the quick answer, `/values` for the
 * form, `/errors` for the error code that the card's own check left on each field, and `/edited` for the
 * rejection that each field was edited after.
 */
function clarifySpec(view: ClarifyView, t: ReturnType<typeof useTranslation>['t']): Spec {
  const { prompt, interaction, enabled } = view
  const { add, spec } = interactionSpec()
  const fields = (prompt.fields ?? []) as ClarifyField[]
  const pending = interaction.state === 'pending'
  const freeText = pending && prompt.allow_free_text
  const answeredBy = interaction.answered_by_name || t('pod.chat_timeline.teammate')
  const answerLabel =
    prompt.choices.find(choice => choice.id === interaction.choice_id)?.label || interaction.answer_text
  return spec(
    add(
      'card',
      'InteractionCard',
      {
        kind: 'question',
        title: view.askedBy
          ? t('pod.superagent.asks_you', { name: view.askedBy })
          : t('pod.chat_timeline.decision_needed'),
        state: interaction.state,
        muted: interaction.state === 'superseded'
      },
      [
        add('question', 'Question', { text: prompt.question }),
        fields.length > 0 &&
          pending &&
          add(
            'form',
            'Form',
            {},
            [
              ...fields.map(field =>
                add(`field:${field.id}`, 'FormField', {
                  field,
                  value: { $bindState: `/values/${field.id}` },
                  error: { $bindState: `/errors/${field.id}` },
                  rejected: view.rejection?.fields[field.id],
                  rejection: view.rejection?.at,
                  edited: { $bindState: `/edited/${field.id}` },
                  disabled: !enabled
                })
              ),
              add('submit', 'ActionButton', {
                label: t('pod.chat_form.submit'),
                variant: 'default',
                size: 'sm',
                submit: true,
                disabled: !enabled
              })
            ],
            { submit: { action: 'submit_form' } }
          ),
        fields.length === 0 &&
          add(
            'choices',
            'Choices',
            {},
            prompt.choices.map((choice, index) =>
              add(
                `choice:${choice.id}`,
                'Choice',
                {
                  label: choice.label,
                  description: choice.description,
                  shortcut: view.shortcuts && index < 4 ? String(index + 1) : undefined,
                  pressed: interaction.choice_id === choice.id,
                  disabled: !enabled
                },
                [],
                { press: { action: 'answer_choice', params: { id: choice.id } } }
              )
            )
          ),
        freeText &&
          fields.length === 0 &&
          add(
            'custom',
            'QuickAnswer',
            {
              label: t('pod.chat_timeline.custom_answer'),
              placeholder: t('pod.chat_timeline.something_else'),
              submit: t('pod.chat_timeline.answer'),
              value: { $bindState: '/text' },
              disabled: !enabled
            },
            [],
            { submit: { action: 'answer_text' } }
          ),
        interaction.state === 'answered' &&
          add('answered', 'Outcome', {
            icon: 'check',
            avatar: Array.from(answeredBy)[0],
            text: [t('pod.chat_timeline.answered_by', { name: answeredBy }), answerLabel].filter(Boolean).join(' · ')
          }),
        freeText &&
          view.canCompose &&
          add('compose', 'Group', { kind: 'compose' }, [
            add(
              'compose-button',
              'ActionButton',
              { label: t('pod.chat_timeline.compose_answer'), variant: 'ghost', size: 'xs', disabled: !enabled },
              [],
              { press: { action: 'compose' } }
            )
          ]),
        interaction.state === 'superseded' && add('superseded', 'Outcome', { text: t('pod.chat_timeline.superseded') }),
        pending &&
          view.decidedElsewhere &&
          add('elsewhere', 'Outcome', { text: t('pod.chat.errors.interaction_not_pending'), live: true }),
        view.submitting && add('submitting', 'Outcome', { text: t('pod.chat_timeline.submitting_answer'), live: true }),
        pending && view.readOnlyReason && add('read-only', 'Outcome', { text: view.readOnlyReason })
      ]
    )
  )
}

export function ChoiceCard({
  prompt,
  interaction,
  onAnswer,
  onComposeAnswer,
  readOnlyReason,
  keyboardActive = false,
  askedBy
}: {
  prompt: ClarifyPrompt
  interaction: ChatInteraction
  /** Names a colleague who asks from a delegated exchange, so the header says who waits for the answer. */
  askedBy?: string
  onAnswer?: (interactionID: string, answer: ClarifyAnswer) => Promise<unknown>
  onComposeAnswer?: (interactionID: string, text: string) => void
  readOnlyReason?: string
  keyboardActive?: boolean
}) {
  const { t } = useTranslation()
  const card = useRef<HTMLDivElement>(null)
  const submitting = useRef(false)
  const reveal = useContext(RevealInTimeline)
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
  const choices = prompt.choices
  const fields = (prompt.fields ?? []) as ClarifyField[]
  const [draft] = useState(() => createStateStore({ text: '', values: initialDraft(fields), errors: {}, edited: {} }))
  const answer = (value: ClarifyAnswer) => {
    if (!enabled || submitting.current) return
    submitting.current = true
    void onAnswer!(prompt.interaction_id, value)
      .catch(() => {})
      .finally(() => {
        submitting.current = false
      })
  }
  /** Moves focus to the first field that a validation flagged; false when it flagged none. */
  const focusFirst = (errors: Record<string, string>) => {
    const first = fields.find(field => errors[field.id])
    if (!first) return false
    // The field moves to the middle of the view once the error messages have rendered.
    requestAnimationFrame(() => {
      const field = card.current?.querySelector<HTMLElement>(`[data-field="${first.id}"]`)
      if (!field) return
      reveal(field)
      field.focus({ preventScroll: true })
    })
    return true
  }
  const fieldErrors =
    requestErrorCode(result?.error) === 'invalid_form_answer'
      ? (requestErrorDetails(result?.error).fields as Record<string, string> | undefined)
      : undefined
  // Each rejected submission brings a new `fieldErrors` object, and FieldError announces each error as an alert.
  useEffect(() => {
    if (fieldErrors) focusFirst(fieldErrors)
  }, [fieldErrors])
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
    <InteractionSurface
      cardRef={card}
      store={draft}
      spec={clarifySpec(
        {
          prompt,
          interaction,
          askedBy,
          enabled,
          submitting: pending,
          decidedElsewhere,
          rejection: fieldErrors && { at: result!.submittedAt, fields: fieldErrors },
          canCompose: !!onComposeAnswer,
          shortcuts: enabled && keyboardActive,
          readOnlyReason: onAnswer ? undefined : readOnlyReason
        },
        t
      )}
      handlers={{
        answer_choice: params => answer({ choiceID: String(params.id) }),
        answer_text: () => {
          const text = String(draft.get('/text') ?? '').trim()
          if (text) answer({ text })
        },
        submit_form: () => {
          if (!enabled) return
          const { values, errors } = collect(fields, draft.get('/values') as Record<string, unknown>)
          draft.set('/errors', errors)
          if (!focusFirst(errors)) answer({ values })
        },
        compose: () => {
          onComposeAnswer?.(prompt.interaction_id, String(draft.get('/text') ?? ''))
          draft.set('/text', '')
        }
      }}
    />
  )
}
