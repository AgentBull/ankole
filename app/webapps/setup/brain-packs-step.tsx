import { RiArrowRightSLine, RiCheckLine, RiEditLine } from '@remixicon/react'
import { Button } from '@ankole/uikit/components/button'
import { Checkbox } from '@ankole/uikit/components/checkbox'
import { Field, FieldDescription, FieldError, FieldLabel } from '@ankole/uikit/components/field'
import { Input } from '@ankole/uikit/components/input'
import { useModel } from '@preact/signals-react'
import { useSignals } from '@preact/signals-react/runtime'
import { useMutation, useQuery, useQueryClient } from '@tanstack/react-query'
import { useEffect, useId } from 'react'
import { useTranslation } from 'react-i18next'
import { setupBrainPacks, updateSetupBrainPacks } from '../common/api/generated/sdk.gen'
import type { SetupBrainPacksResponse as SetupBrainPacks } from '../common/api/generated/types.gen'
import { ErrorBlock } from '../common/error-block'
import { humanizeTechnicalLabel } from '../common/humanize-technical-label'
import { validTenantSlug } from '../common/tenant-slug'
import { SetupPanel } from './layout'
import { BrainPacksStepModel } from './state/brain-packs-step-model'

export function BrainPacksStep({ onContinue }: { onContinue: () => void }) {
  'use no memo'

  useSignals()
  const { t } = useTranslation()
  const model = useModel(BrainPacksStepModel)
  const client = useQueryClient()
  const companyNameID = useId()
  const slugID = useId()
  const slugHintID = useId()
  const query = useQuery({
    queryKey: ['setup-brain-packs'],
    queryFn: () => setupBrainPacks()
  })

  useEffect(() => {
    if (query.data) {
      model.initialize('setup-brain-packs', query.data.selected, {
        displayName: query.data.displayName,
        slug: query.data.slug
      })
    }
  }, [model, query.data])

  const seeded = model.sourceKey.value === 'setup-brain-packs'
  const selected: ReadonlySet<string> = seeded ? model.selectedPacks.value : new Set(query.data?.selected ?? [])
  const slug = model.slug.value
  const slugInvalid = model.editingSlug.value && !validTenantSlug(slug)
  const mutation = useMutation({
    mutationFn: () => updateSetupBrainPacks({ body: { data: model.submission() } }),
    onSuccess: response => {
      client.setQueryData<SetupBrainPacks>(['setup-brain-packs'], previous =>
        previous
          ? {
              ...previous,
              selected: response.packs,
              displayName: response.displayName,
              slug: response.slug
            }
          : previous
      )
      onContinue()
    }
  })

  return (
    <SetupPanel title={t('setup.company_profile_title')}>
      <form
        className="grid gap-7"
        onSubmit={event => {
          event.preventDefault()
          if (model.canSubmit()) mutation.mutate()
        }}>
        <ErrorBlock error={query.error ?? mutation.error} />
        <section className="grid gap-4">
          <Field>
            <FieldLabel htmlFor={companyNameID}>{t('setup.company_name')}</FieldLabel>
            <Input
              id={companyNameID}
              autoComplete="organization"
              autoFocus
              required
              disabled={mutation.isPending}
              maxLength={120}
              value={model.companyName.value}
              onChange={event => {
                model.companyName.value = event.target.value
                mutation.reset()
              }}
            />
          </Field>
          {(model.companyName.value || model.customSlug.value !== undefined) && (
            <div className="grid gap-1.5 rounded-control bg-muted/30 px-3.5 py-3 [overflow-wrap:anywhere]">
              <span className="text-xs text-muted-foreground">{t('setup.tenant_slug')}</span>
              {model.editingSlug.value ? (
                <div className="flex items-center gap-2 text-[13px]">
                  <Input
                    id={slugID}
                    aria-label={t('setup.tenant_slug')}
                    aria-describedby={slugHintID}
                    aria-invalid={slugInvalid}
                    autoFocus
                    autoCapitalize="none"
                    autoComplete="off"
                    spellCheck={false}
                    maxLength={63}
                    className="min-w-0 flex-1"
                    disabled={mutation.isPending}
                    value={model.customSlug.value ?? ''}
                    onChange={event => {
                      model.customSlug.value = event.target.value.toLowerCase()
                      mutation.reset()
                    }}
                  />
                  <Button
                    type="button"
                    variant="outline"
                    disabled={mutation.isPending}
                    onClick={() => {
                      model.editingSlug.value = false
                    }}>
                    {t('setup.done')}
                  </Button>
                </div>
              ) : (
                <div className="flex min-h-8 items-center gap-2 font-mono text-[13px]">
                  <span className="min-w-0 flex-1">
                    {slug ||
                      t(model.transliteration.value === 'loading' ? 'setup.slug_pending' : 'setup.slug_required')}
                  </span>
                  <Button
                    type="button"
                    variant="ghost"
                    size="icon-sm"
                    aria-label={t('setup.edit_slug')}
                    disabled={model.transliteration.value === 'loading' || mutation.isPending}
                    onClick={() => model.editSlug(slug)}>
                    <RiEditLine aria-hidden />
                  </Button>
                </div>
              )}
              {model.editingSlug.value &&
                (slugInvalid ? (
                  <FieldError id={slugHintID}>{t('setup.slug_rules')}</FieldError>
                ) : (
                  <FieldDescription id={slugHintID}>{t('setup.slug_rules')}</FieldDescription>
                ))}
            </div>
          )}
        </section>

        <section className="grid gap-4">
          <div className="grid gap-1.5">
            <h2 className="text-sm font-semibold">{t('setup.business_selection_title')}</h2>
            <p className="max-w-2xl text-sm leading-6 text-muted-foreground">{t('setup.industry_intro')}</p>
          </div>
          <div className="flex items-center gap-3 rounded-control border border-border/70 bg-muted/30 px-4 py-3">
            <span className="grid size-4 shrink-0 place-items-center rounded-xs bg-foreground text-background">
              <RiCheckLine aria-hidden className="size-3" />
            </span>
            <span className="grid min-w-0 gap-0.5">
              <span className="text-sm font-medium">{t('setup.base_pack_name')}</span>
              <span className="text-xs text-muted-foreground">{t('setup.base_pack_note')}</span>
            </span>
          </div>
          <div className="grid grid-cols-1 gap-3 xl:grid-cols-2">
            {(query.data?.packs ?? [])
              .filter(pack => !pack.required)
              .map(pack => (
                <label
                  key={pack.name}
                  className="flex cursor-pointer items-start gap-3 rounded-control border border-border/70 bg-card/60 px-4 py-4 transition-colors has-data-checked:border-border-strong has-data-checked:bg-accent/40">
                  <Checkbox
                    checked={selected.has(pack.name)}
                    disabled={mutation.isPending}
                    onCheckedChange={value => {
                      model.setPackSelected(pack.name, value === true)
                      mutation.reset()
                    }}
                  />
                  <span className="grid min-w-0 flex-1 gap-1.5">
                    <span className="break-words text-sm font-medium leading-5">
                      {humanizeTechnicalLabel(pack.name)}
                    </span>
                    {pack.description ? (
                      <span className="whitespace-pre-wrap break-words text-xs leading-5 text-muted-foreground">
                        {pack.description}
                      </span>
                    ) : null}
                  </span>
                </label>
              ))}
          </div>
        </section>

        <div className="flex flex-wrap items-center gap-3 border-t border-border/70 pt-5">
          <Button
            disabled={!query.data || !model.canSubmit() || mutation.isPending}
            aria-busy={mutation.isPending}
            type="submit">
            {t('setup.save_industry')}
            <RiArrowRightSLine data-icon="inline-end" />
          </Button>
        </div>
      </form>
    </SetupPanel>
  )
}
