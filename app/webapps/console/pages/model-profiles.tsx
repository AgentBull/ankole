import { useMutation, useQuery, Link, useSearchParams } from '../tenant-context'
import { Skeleton, Tabs, TabsContent, TabsList, TabsTrigger } from '@ankole/uikit'
import { recordValue } from '@agentbull/active-support'
import { useModel } from '@preact/signals-react'
import { useSignals } from '@preact/signals-react/runtime'
import { useQuery as useBaseQuery, useQueryClient } from '@tanstack/react-query'
import { useEffect, useRef, type ComponentProps } from 'react'
import { useTranslation } from 'react-i18next'

import {
  listDefaultModelProfilesOptions,
  listSystemPrincipalsOptions,
  listSystemModelProfilesOptions,
  putDefaultProviderHostedMutation
} from '../api/v2/generated/@tanstack/react-query.gen'
import {
  listAiGatewayModelsOptions,
  listAiGatewayProviderKindsOptions,
  listAiGatewayProvidersOptions
} from '../api/v2-site/generated/@tanstack/react-query.gen'
import { ErrorBlock } from '../../common/error-block'
import { dataTenantID } from '../../common/browser-session'
import { PageHeader, PageStack, RefreshButton } from '../console-page'
import { aiGatewayProviders } from '../state/provider-settings'
import {
  ModelProfilesModel,
  POD_PROFILE_NAMES,
  resolvedProviderHosted,
  type ProfileName
} from '../state/model-profiles-model'
import { TenantSwitcher } from '../tenant-switcher'
import { ModelProfileEditorCard } from './model-profile-editor-card'
import { ProfileEditor, RestoreAllInheritanceButton, useModelProfilesDraft } from './model-profiles-editor'

type DefaultsScope = 'tenant' | 'global'
export function ModelProfilesPage() {
  useSignals()
  const { t } = useTranslation()
  const queryClient = useQueryClient()
  const model = useModel(ModelProfilesModel)
  const [params, setParams] = useSearchParams()
  const scope: DefaultsScope = params.get('defaults_scope') === 'tenant' ? 'tenant' : 'global'
  const selectedTenantID = dataTenantID()
  const canLoadConfiguration = scope === 'global' || Boolean(selectedTenantID)
  const configuration = useQuery({
    ...listDefaultModelProfilesOptions({ query: { defaults_scope: scope } }),
    enabled: canLoadConfiguration
  })
  const systemPrincipals = useQuery({
    ...listSystemPrincipalsOptions(),
    enabled: scope === 'tenant' && Boolean(selectedTenantID)
  })
  const providers = useBaseQuery({ ...listAiGatewayProvidersOptions(), select: aiGatewayProviders })
  const providerKinds = useBaseQuery(listAiGatewayProviderKindsOptions())
  const modelCatalog = useBaseQuery(listAiGatewayModelsOptions())
  const draftSourceKey = scope === 'global' ? 'defaults:global' : `defaults:tenant:${selectedTenantID ?? 'none'}`
  const draftStatus = useModelProfilesDraft(
    model,
    draftSourceKey,
    canLoadConfiguration ? configuration.data : undefined
  )
  const saveProviderHosted = useMutation({
    ...putDefaultProviderHostedMutation(),
    onError: () => void queryClient.invalidateQueries()
  })
  const hosted = resolvedProviderHosted(recordValue(configuration.data?.provider_hosted))
  const hostedOverrides = recordValue(configuration.data?.provider_hosted.overrides) ?? {}

  const providerHostedFor = (profile: ProfileName): ComponentProps<typeof ModelProfileEditorCard>['providerHosted'] => {
    if (profile !== 'web_search' && profile !== 'image_generate') return undefined
    const capability = profile
    const mutate = (value: boolean | null) =>
      saveProviderHosted.mutate({ body: { data: { defaults_scope: scope, [capability]: value } } })

    return {
      checked: hosted[capability],
      pending: saveProviderHosted.isPending,
      label: t(`console.models.provider_hosted_${capability}_label`),
      description: t(`console.models.provider_hosted_${capability}_description`),
      replacesProfile: true,
      onChange: next => mutate(next),
      onReset: Object.hasOwn(hostedOverrides, capability) ? () => mutate(null) : undefined,
      resetLabel: t(scope === 'global' ? 'console.models.restore_default' : 'console.models.restore_inheritance')
    }
  }

  return (
    <PageStack>
      <PageHeader
        title={t('console.models.defaults_title')}
        description={t('console.models.defaults_description')}
        actions={<RefreshButton />}
      />
      <Tabs
        value={scope}
        onValueChange={value => {
          const nextScope: DefaultsScope = value === 'tenant' ? 'tenant' : 'global'
          const next = new URLSearchParams(params)
          if (nextScope === 'global') {
            next.delete('defaults_scope')
            next.delete('system_principal')
          } else {
            next.set('defaults_scope', 'tenant')
          }
          setParams(next)
        }}
        className="min-w-0 gap-6">
        <TabsList aria-label={t('console.models.defaults_scope')} className="max-w-full overflow-x-auto">
          <TabsTrigger value="global">{t('console.models.scope_global')}</TabsTrigger>
          <TabsTrigger value="tenant">{t('console.models.scope_tenant')}</TabsTrigger>
        </TabsList>
        <TabsContent key={scope} value={scope} className="grid min-w-0 gap-6">
          <div className="grid gap-1">
            <h3 className="title-section">{t(`console.models.scope_${scope}`)}</h3>
            <p className="text-sm leading-6 text-muted-foreground">{t(`console.models.scope_${scope}_description`)}</p>
            {providers.data?.length === 0 ? (
              <p className="text-sm leading-6 text-muted-foreground">
                {t('console.models.provider_none_hint')}{' '}
                <Link className="link" to="/providers/new">
                  {t('console.models.provider_none_action')}
                </Link>
              </p>
            ) : null}
          </div>
          {scope === 'tenant' ? <TenantSwitcher record search={Object.fromEntries(params)} /> : null}
          {scope === 'tenant' && !selectedTenantID ? (
            <p role="status" className="text-sm text-muted-foreground">
              {t('console.tenants.choose_for_record')}
            </p>
          ) : (
            <>
              <ErrorBlock
                error={
                  configuration.error ??
                  providers.error ??
                  providerKinds.error ??
                  modelCatalog.error ??
                  saveProviderHosted.error
                }
              />
              {draftStatus === 'loading' ? (
                <div className="grid gap-4" aria-busy="true">
                  <Skeleton className="h-48 w-full" />
                  <Skeleton className="h-48 w-full" />
                  <Skeleton className="h-48 w-full" />
                </div>
              ) : configuration.data ? (
                <div className="grid min-w-0 grid-cols-[minmax(0,1fr)] gap-4 [&>*]:min-w-0">
                  {scope === 'tenant' ? (
                    <RestoreAllInheritanceButton
                      configuration={configuration.data}
                      model={model}
                      target={{ defaultsScope: scope }}
                    />
                  ) : null}
                  {POD_PROFILE_NAMES.map(profile => (
                    <ProfileEditor
                      key={`${scope}:${selectedTenantID ?? 'global'}:${profile}`}
                      configuration={configuration.data!}
                      model={model}
                      profile={profile}
                      providerHosted={providerHostedFor(profile)}
                      providerKinds={providerKinds.data?.provider_kinds ?? []}
                      providers={providers.data ?? []}
                      modelCatalog={modelCatalog.data?.models ?? []}
                      target={{ defaultsScope: scope }}
                    />
                  ))}
                </div>
              ) : null}
              {scope === 'tenant' ? (
                <section className="grid min-w-0 gap-6" aria-labelledby="system-principals-title">
                  <div className="grid gap-1">
                    <h2 id="system-principals-title" className="title-section">
                      {t('console.models.system_principals_title')}
                    </h2>
                    <p className="text-sm leading-6 text-muted-foreground">
                      {t('console.models.system_principals_description')}
                    </p>
                  </div>
                  <ErrorBlock error={systemPrincipals.error} />
                  {systemPrincipals.isPending ? <Skeleton className="h-48 w-full" /> : null}
                  {systemPrincipals.data?.system_principals.map(service => (
                    <SystemPrincipalEditor
                      key={service.uid}
                      service={service}
                      selected={params.get('system_principal') === service.uid}
                      providers={providers.data ?? []}
                      providerKinds={providerKinds.data?.provider_kinds ?? []}
                      modelCatalog={modelCatalog.data?.models ?? []}
                    />
                  ))}
                </section>
              ) : null}
            </>
          )}
        </TabsContent>
      </Tabs>
    </PageStack>
  )
}

function SystemPrincipalEditor({
  service,
  selected,
  providers,
  providerKinds,
  modelCatalog
}: {
  service: { uid: string; purpose: string }
  selected: boolean
  providers: ComponentProps<typeof ProfileEditor>['providers']
  providerKinds: ComponentProps<typeof ProfileEditor>['providerKinds']
  modelCatalog: ComponentProps<typeof ProfileEditor>['modelCatalog']
}) {
  useSignals()
  const { t } = useTranslation()
  const section = useRef<HTMLElement>(null)
  const model = useModel(ModelProfilesModel)
  const configuration = useQuery(listSystemModelProfilesOptions({ path: { uid: service.uid } }))
  const draftStatus = useModelProfilesDraft(
    model,
    `system:${dataTenantID() ?? 'privileged'}:${service.uid}`,
    configuration.data
  )

  useEffect(() => {
    if (selected && draftStatus === 'ready') section.current?.scrollIntoView({ block: 'start' })
  }, [selected, draftStatus])

  return (
    <section
      ref={section}
      id={`system-principal-${service.uid}`}
      className="grid min-w-0 scroll-mt-16 gap-4"
      aria-labelledby={`system-title-${service.uid}`}>
      <div className="grid gap-1">
        <h3 id={`system-title-${service.uid}`} className="title-section">
          {service.uid}
        </h3>
        <p className="text-sm leading-6 text-muted-foreground">
          {t(`console.models.system_${service.uid}_description`, { defaultValue: service.purpose })}
        </p>
      </div>
      <ErrorBlock error={configuration.error} />
      {draftStatus === 'loading' ? (
        <Skeleton className="h-48 w-full" />
      ) : configuration.data ? (
        <div className="grid min-w-0 grid-cols-[minmax(0,1fr)] gap-4 [&>*]:min-w-0">
          <RestoreAllInheritanceButton
            configuration={configuration.data}
            model={model}
            target={{ systemUID: service.uid }}
          />
          {POD_PROFILE_NAMES.map(profile => (
            <ProfileEditor
              key={profile}
              target={{ systemUID: service.uid }}
              configuration={configuration.data!}
              model={model}
              profile={profile}
              providers={providers}
              providerKinds={providerKinds}
              modelCatalog={modelCatalog}
              providerHosted={undefined}
            />
          ))}
        </div>
      ) : null}
    </section>
  )
}
