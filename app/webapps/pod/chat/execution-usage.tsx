import { useTranslation } from 'react-i18next'
import type { ExecutionModelUsage, ExecutionUsage } from './types'

// The header rounds tokens to a compact figure; the expanded rows show exact counts.
function useTokenFormat(notation: 'compact' | 'standard') {
  const { i18n } = useTranslation()
  const format = new Intl.NumberFormat(i18n.language, { notation, maximumFractionDigits: 1 })
  return (value: number) => format.format(value)
}

// The header names a model as the Provider reported it, else as requested without its Provider prefix.
function modelName(model: ExecutionModelUsage) {
  return model.provider_model ?? model.model.slice(model.model.indexOf('/') + 1)
}

/** The quiet line in the work header: the main model and the turn's reported tokens. */
export function UsageSummary({ usage }: { usage: ExecutionUsage }) {
  const { t } = useTranslation()
  const tokens = useTokenFormat('compact')
  const [main, ...others] = usage.models
  const total = (usage.input_tokens ?? 0) + (usage.output_tokens ?? 0)
  const unreported = usage.rounds - usage.reported_rounds
  const amount =
    usage.reported_rounds === 0
      ? t('pod.chat_timeline.usage_not_reported')
      : unreported > 0
        ? t('pod.chat_timeline.usage_partial', { tokens: tokens(total), count: unreported })
        : t('pod.chat_timeline.usage_tokens', { tokens: tokens(total) })
  const otherNames = others.map(modelName).join(', ')
  return (
    <span className="ml-2 font-normal text-fg-tertiary tabular-nums">
      {main && (
        <>
          {modelName(main)}
          {others.length > 0 && (
            <span title={otherNames}>
              <span aria-hidden>{` +${others.length}`}</span>
              <span className="sr-only">{t('pod.chat_timeline.usage_more_models', { models: otherNames })}</span>
            </span>
          )}
          {' · '}
        </>
      )}
      {amount}
    </span>
  )
}

/** The expanded rows: each model with its rounds and token counts, and the profile it fell back to. */
export function UsageDetails({ usage }: { usage: ExecutionUsage }) {
  const { t } = useTranslation()
  const tokens = useTokenFormat('standard')
  const count = (value: number | null | undefined) => (value == null ? '—' : tokens(value))
  return (
    <section className="mt-2 grid gap-1.5" aria-label={t('pod.chat_timeline.usage_title')}>
      <h4 className="font-medium text-balance text-fg-secondary">{t('pod.chat_timeline.usage_title')}</h4>
      {usage.models.map(model => {
        const parts = [
          model.served_profile && model.model_profile ? `${model.model_profile} → ${model.served_profile}` : null,
          t('pod.chat_timeline.usage_rounds', { count: model.rounds }),
          model.reported_rounds < model.rounds
            ? t('pod.chat_timeline.usage_model_reported', { reported: model.reported_rounds, rounds: model.rounds })
            : null
        ].filter(Boolean)
        return (
          <div key={`${model.model}:${model.provider_model}:${model.model_profile}:${model.served_profile}`}>
            <div className="text-fg-secondary">
              <span className="break-all text-foreground" title={model.model}>
                {modelName(model)}
              </span>
              {` · ${parts.join(' · ')}`}
            </div>
            <div className="flex flex-wrap gap-x-3 tabular-nums">
              <span>
                {t('pod.chat_timeline.usage_input')} {count(model.input_tokens)}
              </span>
              <span>
                {t('pod.chat_timeline.usage_output')} {count(model.output_tokens)}
              </span>
              <span>
                {t('pod.chat_timeline.usage_cached')} {count(model.cached_input_tokens)}
              </span>
              <span>
                {t('pod.chat_timeline.usage_reasoning')} {count(model.reasoning_tokens)}
              </span>
            </div>
          </div>
        )
      })}
    </section>
  )
}
