import { RiArrowRightSLine } from '@remixicon/react'
import { Button } from '@ankole/uikit/components/button'
import { Checkbox } from '@ankole/uikit/components/checkbox'
import { useModel } from '@preact/signals-react'
import { useSignals } from '@preact/signals-react/runtime'
import { useMutation, useQuery } from '@tanstack/react-query'
import { useEffect } from 'react'
import { useTranslation } from 'react-i18next'
import { internalAPIGet, internalAPIPut } from '../common/internal-api-client'
import { ErrorBlock } from '../common/error-block'
import { SetupPanel } from './layout'
import { BrainPacksStepModel, type BrainPack } from './state/brain-packs-step-model'

/**
 * Industry step: picks the Brain schema packs the instance installs at setup
 * completion. The general pack is always included, so it renders as a checked
 * disabled row instead of a choice.
 */
export function BrainPacksStep({ onContinue }: { onContinue: () => void }) {
  useSignals()
  const { t } = useTranslation()
  const model = useModel(BrainPacksStepModel)
  const query = useQuery({
    queryKey: ['setup-brain-packs'],
    queryFn: () => internalAPIGet<{ packs: BrainPack[]; selected: string[] }>('/.internal-apis/setup/brain-packs')
  })

  useEffect(() => {
    if (query.data) model.initialize('setup-brain-packs', query.data.selected)
  }, [model, query.data])

  const seeded = model.sourceKey.value === 'setup-brain-packs'
  const selected: ReadonlySet<string> = seeded ? model.selectedPacks.value : new Set(query.data?.selected ?? [])
  const mutation = useMutation({
    mutationFn: () => internalAPIPut<{ packs: string[] }>('/.internal-apis/setup/brain-packs', model.submission()),
    onSuccess: onContinue
  })

  return (
    <SetupPanel title={t('setup.choose_industry')}>
      <p className="text-sm leading-6 text-muted-foreground">{t('setup.industry_intro')}</p>
      <ErrorBlock error={query.error ?? mutation.error} />
      <div className="grid grid-cols-1 gap-3 xl:grid-cols-2">
        {(query.data?.packs ?? []).map(pack => {
          const checked = pack.required || selected.has(pack.name)

          return (
            <label
              key={pack.name}
              className={`flex items-start gap-3 border border-border/70 bg-card/60 px-4 py-4 ${
                pack.required ? 'opacity-80' : ''
              }`}>
              <Checkbox
                checked={checked}
                disabled={pack.required}
                onCheckedChange={value => model.setPackSelected(pack.name, value === true)}
              />
              <span className="grid min-w-0 flex-1 gap-2">
                <span className="flex flex-wrap items-center gap-2 text-sm font-semibold leading-5">
                  <span className="break-words">{pack.name}</span>
                  {pack.version ? (
                    <span className="font-mono text-xs text-muted-foreground">{pack.version}</span>
                  ) : null}
                  {pack.required ? (
                    <span className="text-xs font-normal text-muted-foreground">{t('setup.pack_always_included')}</span>
                  ) : null}
                </span>
                {pack.description ? (
                  <span className="whitespace-pre-wrap break-words text-xs leading-5 text-muted-foreground">
                    {pack.description}
                  </span>
                ) : null}
              </span>
            </label>
          )
        })}
      </div>
      <div className="flex flex-wrap items-center gap-3 border-t border-border/70 pt-5">
        <Button disabled={!query.data || mutation.isPending} onClick={() => mutation.mutate()} type="button">
          {t('setup.save_industry')}
          <RiArrowRightSLine data-icon="inline-end" />
        </Button>
      </div>
    </SetupPanel>
  )
}
