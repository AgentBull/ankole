import { match } from '@agentbull/active-support'
import { Input, Progress, ProgressLabel, ProgressValue, Skeleton, cn, toast } from '@ankole/uikit'
import { useModel } from '@preact/signals-react'
import { useSignals } from '@preact/signals-react/runtime'
import { useMutation, useQuery, useQueryClient } from '@tanstack/react-query'
import { useMemo, useRef, type ReactNode } from 'react'
import { useTranslation } from 'react-i18next'
import {
  ankoleWebAgentControllerDeleteTokenQuotaMutation,
  ankoleWebAgentControllerPutTokenQuotaMutation,
  ankoleWebAgentControllerResetTokenQuotaMutation,
  ankoleWebAgentControllerShowTokenQuotaOptions,
  ankoleWebAgentControllerShowTokenQuotaQueryKey
} from '../api/generated/@tanstack/react-query.gen'
import { requestErrorMessage } from '../../common/request-errors'
import { ErrorBlock } from '../../common/error-block'
import { ConfirmDeleteButton, LabeledField, SaveButton, StatusIndicator } from '../console-form'
import { formatConsoleDate } from '../console-primitives'
import {
  TokenQuotaEditorModel,
  draftFromTokenQuota,
  emptyTokenQuotaDraft,
  type TokenQuotaDraftError
} from '../state/token-quota-editor-model'
import { timeZoneOffsetLabel } from '../state/timezone-editor'
import { useEditorDraft } from '../use-editor-draft'

/**
 * Token quota of one Agent, embedded in the agent editor.
 *
 * The section owns its own quota request, so a save, a removal, and a period
 * reset invalidate only that request. Removing the quota leaves the Agent with
 * no limit; a reset ends the current period at once and starts an empty one.
 * Neither touches the recorded usage.
 */
export function TokenQuotaEditor({ agentUID }: { agentUID: string }) {
  useSignals()
  const { t, i18n } = useTranslation()
  const queryClient = useQueryClient()
  // The picker edits wall-clock time in the browser's zone; the hint names that
  // zone so the operator knows which midnight a date means.
  const timeZone = Intl.DateTimeFormat().resolvedOptions().timeZone
  const timeZoneLabel = [timeZone, timeZoneOffsetLabel(timeZone, i18n.language)].filter(Boolean).join(' ')
  const model = useModel(TokenQuotaEditorModel)
  const periodDaysInput = useRef<HTMLInputElement>(null)
  const periodStartAtInput = useRef<HTMLInputElement>(null)
  const limitTokensInput = useRef<HTMLInputElement>(null)

  const quota = useQuery(ankoleWebAgentControllerShowTokenQuotaOptions({ path: { agent_uid: agentUID } }))
  const storedQuota = quota.data?.token_quota ?? null
  const usage = quota.data?.usage ?? null
  // A failed read still opens the fields, on an empty draft, so the section
  // shows the failure instead of a skeleton that never resolves.
  const draftSource = useMemo(
    () => (quota.isPending ? undefined : draftFromTokenQuota(quota.data?.token_quota)),
    [quota.data, quota.isPending]
  )
  const draftStatus = useEditorDraft(model, {
    identity: { resource: 'token-quota', agentUID },
    source: draftSource
  })

  const refresh = () =>
    void queryClient.invalidateQueries({
      queryKey: ankoleWebAgentControllerShowTokenQuotaQueryKey({ path: { agent_uid: agentUID } })
    })

  // The save failure renders in the section's ErrorBlock, next to the fields
  // that caused it. The removal and the reset carry no field context, so they
  // report through a toast instead.
  const save = useMutation({
    ...ankoleWebAgentControllerPutTokenQuotaMutation(),
    onSuccess: response => {
      toast.success(t('console.agents.token_quota_saved'))
      model.markSaved(draftFromTokenQuota(response.token_quota))
      refresh()
    }
  })
  const clear = useMutation({
    ...ankoleWebAgentControllerDeleteTokenQuotaMutation(),
    onSuccess: () => {
      toast.success(t('console.agents.token_quota_cleared'))
      model.markSaved(emptyTokenQuotaDraft())
      refresh()
    },
    onError: error => toast.error(requestErrorMessage(error))
  })
  // A reset writes a new period start, so the draft adopts the stored quota
  // again. An unsaved edit of the start time cannot survive it.
  const reset = useMutation({
    ...ankoleWebAgentControllerResetTokenQuotaMutation(),
    onSuccess: response => {
      toast.success(t('console.agents.token_quota_reset_done'))
      model.markSaved(draftFromTokenQuota(response.token_quota))
      refresh()
    },
    onError: error => toast.error(requestErrorMessage(error))
  })

  const submit = () => {
    model.clearValidation()
    const submission = model.submission()
    if (!submission.ok) {
      model.validationError.value = submission.error
      match(submission.error)
        .with('period_days_required', 'period_days_invalid', () => periodDaysInput.current?.focus())
        .with('period_start_at_required', 'period_start_at_invalid', () => periodStartAtInput.current?.focus())
        .with('limit_tokens_required', 'limit_tokens_invalid', () => limitTokensInput.current?.focus())
        .exhaustive()
      return
    }
    save.mutate({ body: submission.body, path: { agent_uid: agentUID } })
  }

  // Blur-time required and pattern feedback comes from LabeledField; these
  // carry the submit-time decisions of the draft model and reuse the same
  // shared templates, so the text never changes between blur and submit.
  const draftError = model.validationError.value
  const fieldError = (labelKey: string, required: TokenQuotaDraftError, invalid: TokenQuotaDraftError) => {
    if (draftError === required) return t('common.field_required', { field: t(labelKey) })
    if (draftError === invalid) return t('common.field_invalid', { field: t(labelKey) })
    return undefined
  }
  // The instant needs its own message: the generic invalid text does not say
  // that the date and the time must both be complete.
  const instantInvalidText = t('console.agents.token_quota_period_start_at_invalid')
  const periodStartAtError =
    draftError === 'period_start_at_required'
      ? t('common.field_required', { field: t('console.agents.token_quota_period_start_at') })
      : draftError === 'period_start_at_invalid'
        ? instantInvalidText
        : undefined
  const pending = save.isPending || clear.isPending || reset.isPending

  return (
    <section className="grid gap-4">
      <div className="grid gap-1">
        <h3 className="text-lg font-semibold tracking-normal">{t('console.agents.token_quota_title')}</h3>
        <p className="text-sm leading-6 text-muted-foreground">{t('console.agents.token_quota_description')}</p>
      </div>
      <ErrorBlock error={quota.error ?? save.error} />
      {draftStatus === 'loading' ? (
        <Skeleton className="h-56 w-full" aria-busy="true" />
      ) : (
        <div className="grid gap-5 border border-border bg-card p-5 md:p-6">
          {storedQuota && usage ? (
            <div className="grid gap-4">
              <QuotaUsageBar
                label={t('console.agents.token_quota_used')}
                usedTokens={usage.used_tokens}
                limitTokens={storedQuota.limit_tokens}
                exceeded={usage.exceeded}
                exceededLabel={t('console.agents.token_quota_exceeded')}
              />
              <dl className="grid gap-3 sm:grid-cols-2">
                <QuotaFact label={t('console.agents.token_quota_window_started')}>
                  {formatConsoleDate(usage.window_started_at)}
                </QuotaFact>
                <QuotaFact label={t('console.agents.token_quota_window_ends')}>
                  {formatConsoleDate(usage.window_ends_at)}
                </QuotaFact>
              </dl>
            </div>
          ) : (
            <p className="text-sm leading-6 text-muted-foreground">{t('console.agents.token_quota_none')}</p>
          )}

          <div className="grid gap-5 md:grid-cols-3">
            <LabeledField
              label={t('console.agents.token_quota_period_days')}
              description={t('console.agents.token_quota_period_days_hint')}
              error={fieldError(
                'console.agents.token_quota_period_days',
                'period_days_required',
                'period_days_invalid'
              )}
              required>
              <Input
                type="number"
                min="1"
                step="1"
                inputMode="numeric"
                ref={periodDaysInput}
                value={model.periodDays.value}
                onChange={event => {
                  model.periodDays.value = event.target.value
                  if (draftError === 'period_days_required' || draftError === 'period_days_invalid') {
                    model.clearValidation()
                  }
                }}
              />
            </LabeledField>
            <LabeledField
              label={t('console.agents.token_quota_period_start_at')}
              description={t('console.agents.token_quota_period_start_at_hint', { zone: timeZoneLabel })}
              error={periodStartAtError}
              invalidError={instantInvalidText}
              required>
              <Input
                type="datetime-local"
                step="1"
                ref={periodStartAtInput}
                value={model.periodStartAt.value}
                onChange={event => {
                  model.periodStartAt.value = event.target.value
                  if (draftError === 'period_start_at_required' || draftError === 'period_start_at_invalid') {
                    model.clearValidation()
                  }
                }}
              />
            </LabeledField>
            <LabeledField
              label={t('console.agents.token_quota_limit_tokens')}
              description={t('console.agents.token_quota_limit_tokens_hint')}
              error={fieldError(
                'console.agents.token_quota_limit_tokens',
                'limit_tokens_required',
                'limit_tokens_invalid'
              )}
              required>
              <Input
                type="number"
                min="1"
                step="1"
                inputMode="numeric"
                ref={limitTokensInput}
                value={model.limitTokens.value}
                onChange={event => {
                  model.limitTokens.value = event.target.value
                  if (draftError === 'limit_tokens_required' || draftError === 'limit_tokens_invalid') {
                    model.clearValidation()
                  }
                }}
              />
            </LabeledField>
          </div>

          <div className="flex flex-wrap items-center gap-2">
            <SaveButton
              disabled={pending || !model.dirty.value}
              loading={save.isPending}
              size="sm"
              type="button"
              onClick={submit}>
              {t('common.save')}
            </SaveButton>
            {model.dirty.value && !pending ? (
              <span className="text-xs text-muted-foreground">{t('common.unsaved_changes')}</span>
            ) : null}
            {storedQuota ? (
              <>
                <ConfirmDeleteButton
                  label={t('console.agents.token_quota_reset')}
                  pending={pending}
                  size="sm"
                  variant="outline"
                  confirm={{
                    title: t('console.agents.token_quota_reset_confirm_title'),
                    description: t('console.agents.token_quota_reset_confirm_description', { id: agentUID }),
                    confirmLabel: t('console.agents.token_quota_reset')
                  }}
                  onConfirm={() => reset.mutate({ path: { agent_uid: agentUID } })}
                />
                <ConfirmDeleteButton
                  label={t('console.agents.token_quota_clear')}
                  pending={pending}
                  size="sm"
                  confirm={{
                    title: t('console.agents.token_quota_clear_confirm_title'),
                    description: t('console.agents.token_quota_clear_confirm_description', { id: agentUID }),
                    confirmLabel: t('console.agents.token_quota_clear')
                  }}
                  onConfirm={() => clear.mutate({ path: { agent_uid: agentUID } })}
                />
              </>
            ) : null}
          </div>
        </div>
      )}
    </section>
  )
}

// The bar fills to the limit and stays full past it; the number keeps the real
// share so an over-limit Agent still reads as over.
const QUOTA_WARNING_SHARE = 0.8

function QuotaUsageBar({
  exceeded,
  exceededLabel,
  label,
  limitTokens,
  usedTokens
}: {
  exceeded: boolean
  exceededLabel: string
  label: string
  limitTokens: number
  usedTokens: number
}) {
  const share = limitTokens > 0 ? usedTokens / limitTokens : 0
  const percent = Math.round(share * 100)
  const tone = exceeded ? 'danger' : share >= QUOTA_WARNING_SHARE ? 'warning' : 'default'

  return (
    <Progress
      value={usedTokens}
      max={limitTokens}
      aria-label={label}
      className={cn(
        'gap-1.5',
        tone === 'danger' && '[&_[data-slot=progress-indicator]]:bg-destructive',
        tone === 'warning' && '[&_[data-slot=progress-indicator]]:bg-warning'
      )}>
      <ProgressLabel className="flex flex-wrap items-center gap-2">
        <span>{label}</span>
        <span className="tabular-nums">
          {usedTokens.toLocaleString()} / {limitTokens.toLocaleString()}
        </span>
        {exceeded ? <StatusIndicator tone="danger">{exceededLabel}</StatusIndicator> : null}
      </ProgressLabel>
      <ProgressValue className={cn(tone === 'danger' && 'text-destructive')}>{() => `${percent}%`}</ProgressValue>
    </Progress>
  )
}

function QuotaFact({ children, label }: { children: ReactNode; label: string }) {
  return (
    <div className="grid content-start gap-1">
      <dt className="text-xs text-muted-foreground">{label}</dt>
      <dd className="flex flex-wrap items-center gap-2 text-sm tabular-nums">{children}</dd>
    </div>
  )
}
