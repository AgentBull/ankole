import { Badge, Button, toast } from '@ankole/uikit'
import { useMutation, useQuery, useQueryClient } from '@tanstack/react-query'
import type { ReactNode } from 'react'
import { useTranslation } from 'react-i18next'
import { podKeys } from '../api'
import { choosePodNextStep, podNextSteps } from '../api/generated/sdk.gen'
import type { PodNextStepsResponse } from '../api/generated/types.gen'

type NextStep = PodNextStepsResponse['steps'][number]

/** The draft a chosen step leaves in the composer, for the Human to edit before sending. */
export function nextStepDraft(step: Pick<NextStep, 'title'>, expected: string) {
  return `${step.title}\n\n${expected}`
}

const sameSteps = (left: NextStep[], right: NextStep[]) =>
  left.length === right.length && left.every((step, index) => step.id === right[index]?.id)

/**
 * The personal assistant's next steps on the chat home. Until a menu exists, or when the
 * assistant cannot write one, the home keeps its fixed starters.
 */
export function NextStepsMenu({ fallback, onChoose }: { fallback: ReactNode; onChoose(text: string): void }) {
  const { t, i18n } = useTranslation()
  const client = useQueryClient()
  const menu = useQuery({
    queryKey: podKeys.nextSteps,
    queryFn: () => podNextSteps({ body: { data: { locale: i18n.language } } }),
    staleTime: 60_000,
    retry: false,
    refetchOnWindowFocus: false
  })
  const refresh = useMutation({
    mutationFn: () => podNextSteps({ body: { data: { refresh: true, locale: i18n.language } } }),
    onSuccess: data => {
      // When no new menu could be written, the server keeps the current one; say so instead of looking idle.
      if (sameSteps(data.steps, menu.data?.steps ?? [])) toast.info(t('pod.next_steps.no_others'))
      client.setQueryData(podKeys.nextSteps, data)
    },
    onError: () => toast.error(t('pod.next_steps.no_others'))
  })
  const choose = useMutation({
    mutationFn: (id: string) => choosePodNextStep({ path: { id } }),
    onSettled: () => client.invalidateQueries({ queryKey: podKeys.nextSteps })
  })
  const steps = menu.data?.steps ?? []
  if (!steps.length) return fallback
  return (
    <section className="pod-chat-next-steps">
      <div className="pod-chat-next-steps-header">
        <h2>{t('pod.next_steps.title')}</h2>
        <Button size="xs" variant="ghost" disabled={refresh.isPending} onClick={() => refresh.mutate()}>
          {t(refresh.isPending ? 'pod.next_steps.refreshing' : 'pod.next_steps.refresh')}
        </Button>
      </div>
      <ol>
        {steps.map(step => (
          <li key={step.id}>
            <button
              type="button"
              onClick={() => {
                choose.mutate(step.id)
                onChoose(nextStepDraft(step, t('pod.next_steps.expected', { outcome: step.outcome })))
              }}>
              <span className="pod-chat-next-step-title">
                {step.title}
                {step.ambitious && (
                  <Badge size="sm" variant="info">
                    {t('pod.next_steps.ambitious')}
                  </Badge>
                )}
              </span>
              <span className="pod-chat-next-step-outcome">{step.outcome}</span>
              <span className="pod-chat-next-step-meta">
                {t('pod.next_steps.meta', { effort: step.effort, whyNow: step.whyNow })}
              </span>
            </button>
          </li>
        ))}
      </ol>
    </section>
  )
}
