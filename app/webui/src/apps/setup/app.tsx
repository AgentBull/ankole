import { RiArrowRightSLine, RiLoginCircleLine } from '@remixicon/react'
import { resolveBullXPluginLocalizedText, type BullXPluginJsonValue } from '@agentbull/bullx-sdk/plugins'
import { useMutation, useQuery, useQueryClient } from '@tanstack/react-query'
import { useEffect, useMemo, useState } from 'react'
import { useTranslation } from 'react-i18next'
import { Alert, AlertDescription, AlertTitle } from '@/uikit/components/alert'
import { nativeLocaleLabel } from '@/config/i18n-locales'
import {
  defaultPluginConfigForSetup,
  getPluginConfigPath as getPath,
  mergePluginConfigObjects as mergeJsonRecords,
  setPluginConfigPath as setPath,
  type PluginConfigJsonObject
} from '@/plugins/config-json'
import { Button } from '@/uikit/components/button'
import { Card, CardContent, CardHeader, CardTitle } from '@/uikit/components/card'
import { Checkbox } from '@/uikit/components/checkbox'
import { Field, FieldDescription, FieldError, FieldGroup, FieldLabel } from '@/uikit/components/field'
import { Input } from '@/uikit/components/input'
import { Select, SelectContent, SelectItem, SelectTrigger, SelectValue } from '@/uikit/components/select'
import { apiErrorMessage, apiGet, apiPost, apiPut } from '@/lib/api'
import { SetupLayout } from './layout'

type LocalizedText = string | Record<string, string>

interface SetupState {
  completed: boolean
  authenticated: boolean
  currentLocale: string
  availableLocales: string[]
}

interface Plugin {
  id: string
  metadata?: {
    displayName?: LocalizedText
    display_name?: LocalizedText
    description?: LocalizedText
  }
}

interface PluginsResponse {
  plugins: Plugin[]
  enabledPluginIds: string[]
}

interface SetupField {
  path: string[]
  type: 'text' | 'password' | 'select' | 'checkbox' | 'number'
  label: LocalizedText
  description?: LocalizedText
  options?: Array<{ value: string; label: LocalizedText }>
  defaultValue?: JsonValue
}

type JsonValue = BullXPluginJsonValue

interface AdapterDescriptor {
  id: string
  pluginId: string
  setup?: {
    displayName?: LocalizedText
    description?: LocalizedText
    defaultProviderId?: string
    defaultConfig?: JsonValue
    fields: SetupField[]
  }
}

interface AdaptersResponse {
  adapters: AdapterDescriptor[]
}

export function SetupApp() {
  const queryClient = useQueryClient()
  const { t } = useTranslation()
  const [step, setStep] = useState<'plugins' | 'identity'>('plugins')
  const state = useQuery({
    queryKey: ['setup-state'],
    queryFn: () => apiGet<SetupState>('/api/setup/state')
  })

  if (state.data?.completed) {
    window.location.assign('/')
    return null
  }

  return (
    <SetupLayout>
      <section className="grid flex-1 grid-cols-1 gap-6 py-8 lg:grid-cols-[220px_minmax(0,1fr)]">
        <nav className="h-fit border border-border/70 bg-background/85 p-3 backdrop-blur">
          <ol className="flex flex-row gap-2 overflow-x-auto lg:flex-col lg:overflow-visible">
            {(['plugins', 'identity'] as const).map((id, index) => (
              <li key={id} className="min-w-28 lg:min-w-0">
                <button
                  type="button"
                  data-active={state.data?.authenticated && id === step ? true : undefined}
                  disabled={!state.data?.authenticated}
                  onClick={() => setStep(id)}
                  className="flex h-10 w-full items-center gap-3 border border-transparent px-3 text-left text-sm text-muted-foreground data-active:border-primary data-active:bg-primary data-active:text-primary-foreground disabled:cursor-default disabled:opacity-80">
                  <span className="font-mono text-xs">{String(index + 1).padStart(2, '0')}</span>
                  <span className="truncate">
                    {t(id === 'plugins' ? 'setup.steps.plugins' : 'setup.steps.identity')}
                  </span>
                </button>
              </li>
            ))}
          </ol>
        </nav>
        <div className="min-w-0">
          {!state.data?.authenticated ? (
            <BootstrapGate
              setupState={state.data}
              onAuthenticated={() => queryClient.invalidateQueries({ queryKey: ['setup-state'] })}
            />
          ) : step === 'plugins' ? (
            <PluginsStep onContinue={() => setStep('identity')} />
          ) : (
            <IdentityStep />
          )}
        </div>
      </section>
    </SetupLayout>
  )
}

function BootstrapGate({ setupState, onAuthenticated }: { setupState?: SetupState; onAuthenticated: () => void }) {
  const { i18n, t } = useTranslation()
  const currentLocale = setupState?.currentLocale ?? i18n.resolvedLanguage ?? i18n.language
  const [locale, setLocale] = useState(currentLocale)
  const [activationCode, setActivationCode] = useState('')
  const availableLocales = useMemo(
    () => uniqueStrings([...(setupState?.availableLocales ?? []), locale]),
    [locale, setupState?.availableLocales]
  )

  useEffect(() => {
    setLocale(currentLocale)
  }, [currentLocale])

  const mutation = useMutation({
    mutationFn: () => apiPost('/api/setup/sessions', { activationCode, locale }),
    onSuccess: onAuthenticated
  })

  function changeLocale(nextLocale: string | null) {
    if (!nextLocale) return

    setLocale(nextLocale)
    void i18n.changeLanguage(nextLocale)
  }

  function localeLabel(value: string | null) {
    return value ? nativeLocaleLabel(value) : ''
  }

  return (
    <Panel
      title={t('setup.session.panel_title')}
      footer={
        <Button type="button" disabled={mutation.isPending} onClick={() => mutation.mutate()}>
          {t('setup.continue')}
          <RiArrowRightSLine data-icon="inline-end" />
        </Button>
      }>
      <InfoAlert title={t('setup.session.log_hint_title')}>{t('setup.session.log_hint_body')}</InfoAlert>
      <ErrorAlert error={mutation.error} />
      <FieldGroup className="grid gap-5 md:grid-cols-2">
        <Field>
          <FieldLabel>{t('setup.session.locale_label')}</FieldLabel>
          <Select value={locale} onValueChange={changeLocale}>
            <SelectTrigger className="w-full">
              <SelectValue>{localeLabel}</SelectValue>
            </SelectTrigger>
            <SelectContent>
              {availableLocales.map(availableLocale => (
                <SelectItem key={availableLocale} value={availableLocale}>
                  {localeLabel(availableLocale)}
                </SelectItem>
              ))}
            </SelectContent>
          </Select>
        </Field>
        <Field>
          <FieldLabel>{t('setup.session.bootstrap_code_label')}</FieldLabel>
          <Input
            value={activationCode}
            autoComplete="one-time-code"
            onChange={event => setActivationCode(event.target.value.toUpperCase())}
          />
        </Field>
      </FieldGroup>
    </Panel>
  )
}

function PluginsStep({ onContinue }: { onContinue: () => void }) {
  const { i18n, t } = useTranslation()
  const query = useQuery({
    queryKey: ['setup-plugins'],
    queryFn: () => apiGet<PluginsResponse>('/api/setup/plugins')
  })
  const [selected, setSelected] = useState<Set<string> | null>(null)
  const selectedIds = selected ?? new Set(query.data?.enabledPluginIds ?? [])
  const mutation = useMutation({
    mutationFn: () => apiPut('/api/setup/plugins/enabled', { pluginIds: [...selectedIds] }),
    onSuccess: onContinue
  })

  return (
    <Panel
      title={t('setup.plugins.panel_title')}
      footer={
        <Button type="button" disabled={mutation.isPending || !query.data} onClick={() => mutation.mutate()}>
          {t('setup.plugins.save_button')}
          <RiArrowRightSLine data-icon="inline-end" />
        </Button>
      }>
      <ErrorAlert error={query.error ?? mutation.error} />
      <div className="grid gap-3 xl:grid-cols-2">
        {(query.data?.plugins ?? []).map(plugin => {
          const checked = selectedIds.has(plugin.id)
          const displayName =
            localizedText(plugin.metadata?.displayName ?? plugin.metadata?.display_name, i18n.language) ?? plugin.id
          const description = localizedText(plugin.metadata?.description, i18n.language)

          return (
            <label key={plugin.id} className="flex items-start gap-3 border border-border/70 bg-card/60 px-4 py-4">
              <Checkbox
                checked={checked}
                onCheckedChange={value => {
                  const next = new Set(selectedIds)
                  value ? next.add(plugin.id) : next.delete(plugin.id)
                  setSelected(next)
                }}
              />
              <span className="grid min-w-0 flex-1 gap-2">
                <span className="break-words text-sm font-semibold leading-5">{displayName}</span>
                {description ? (
                  <span className="whitespace-pre-wrap break-words text-xs leading-5 text-muted-foreground">
                    {description}
                  </span>
                ) : null}
              </span>
            </label>
          )
        })}
      </div>
    </Panel>
  )
}

function IdentityStep() {
  const { i18n, t } = useTranslation()
  const query = useQuery({
    queryKey: ['setup-identity-provider-adapters'],
    queryFn: () => apiGet<AdaptersResponse>('/api/setup/identity-provider-adapters')
  })
  const adapters = query.data?.adapters ?? []
  const [adapterId, setAdapterId] = useState<string>('')
  const activeAdapter = adapters.find(adapter => adapter.id === (adapterId || adapters[0]?.id))
  const [providerId, setProviderId] = useState('')
  const [config, setConfig] = useState<PluginConfigJsonObject>({})
  const initialConfig = useMemo(() => defaultConfigForAdapter(activeAdapter), [activeAdapter])
  /*
   * providerId is the globally unique external identity namespace stored under
   * identity_providers.<providerId>. It is intentionally not nested under the
   * adapter id because the same installation must never have two providers with
   * the same Principal external-identity namespace.
   */
  const effectiveProviderId =
    providerId || activeAdapter?.setup?.defaultProviderId || `${activeAdapter?.id ?? 'provider'}-main`
  const effectiveConfig = useMemo(() => mergeJsonRecords(initialConfig, config), [initialConfig, config])
  const saveMutation = useMutation({
    mutationFn: () =>
      apiPut(`/api/setup/identity-providers/${encodeURIComponent(effectiveProviderId)}`, {
        adapter: activeAdapter?.id,
        config: effectiveConfig,
        enabled: true
      })
  })
  const oidcMutation = useMutation({
    mutationFn: async () => {
      /*
       * The first successful OIDC login is the admin handoff. Config is saved
       * immediately before redirect so the callback can instantiate the same
       * provider from durable app-config instead of trusting browser state.
       */
      await saveMutation.mutateAsync()
      return apiPost<{ authorizationUrl: string }>(
        `/api/setup/identity-providers/${encodeURIComponent(effectiveProviderId)}/oidc/authorizations`,
        {}
      )
    },
    onSuccess: result => {
      window.location.assign(result.authorizationUrl)
    }
  })

  return (
    <Panel
      title={t('setup.identity.panel_title')}
      footer={
        <Button type="button" disabled={!activeAdapter || oidcMutation.isPending} onClick={() => oidcMutation.mutate()}>
          {t('setup.identity.oidc_button')}
          <RiLoginCircleLine data-icon="inline-end" />
        </Button>
      }>
      <ErrorAlert error={query.error ?? saveMutation.error ?? oidcMutation.error} />
      <FieldGroup className="grid gap-5 md:grid-cols-2">
        <Field>
          <FieldLabel>{t('setup.identity.adapter_label')}</FieldLabel>
          <Select value={activeAdapter?.id ?? ''} onValueChange={value => setAdapterId(value ?? '')}>
            <SelectTrigger className="w-full">
              <SelectValue />
            </SelectTrigger>
            <SelectContent>
              {adapters.map(adapter => (
                <SelectItem key={adapter.id} value={adapter.id}>
                  {localizedText(adapter.setup?.displayName, i18n.language) ?? adapter.id}
                </SelectItem>
              ))}
            </SelectContent>
          </Select>
        </Field>
        <Field>
          <FieldLabel>{t('setup.identity.provider_id_label')}</FieldLabel>
          <Input value={effectiveProviderId} onChange={event => setProviderId(event.target.value)} />
          <FieldDescription>{t('setup.identity.provider_id_description')}</FieldDescription>
        </Field>
      </FieldGroup>
      <FieldGroup className="grid gap-5 md:grid-cols-2">
        {(activeAdapter?.setup?.fields ?? []).map(field => (
          <SetupConfigField
            key={field.path.join('.')}
            field={field}
            locale={i18n.language}
            value={getPath(effectiveConfig, field.path)}
            onChange={value => setConfig(previous => setPath(previous, field.path, value))}
          />
        ))}
      </FieldGroup>
    </Panel>
  )
}

function SetupConfigField({
  field,
  locale,
  value,
  onChange
}: {
  field: SetupField
  locale: string
  value: JsonValue | undefined
  onChange(value: JsonValue): void
}) {
  const label = localizedText(field.label, locale) ?? field.path.join('.')
  const description = localizedText(field.description, locale)

  if (field.type === 'checkbox') {
    return (
      <Field orientation="horizontal" className="items-center justify-between">
        <div>
          <FieldLabel>{label}</FieldLabel>
          {description ? <FieldDescription>{description}</FieldDescription> : null}
        </div>
        <Checkbox checked={Boolean(value)} onCheckedChange={checked => onChange(checked === true)} />
      </Field>
    )
  }

  if (field.type === 'select') {
    return (
      <Field>
        <FieldLabel>{label}</FieldLabel>
        <Select value={typeof value === 'string' ? value : ''} onValueChange={next => onChange(next ?? '')}>
          <SelectTrigger className="w-full">
            <SelectValue />
          </SelectTrigger>
          <SelectContent>
            {(field.options ?? []).map(option => (
              <SelectItem key={option.value} value={option.value}>
                {localizedText(option.label, locale) ?? option.value}
              </SelectItem>
            ))}
          </SelectContent>
        </Select>
        {description ? <FieldDescription>{description}</FieldDescription> : null}
      </Field>
    )
  }

  return (
    <Field>
      <FieldLabel>{label}</FieldLabel>
      <Input
        type={field.type === 'password' ? 'password' : field.type === 'number' ? 'number' : 'text'}
        value={value == null ? '' : String(value)}
        onChange={event => onChange(field.type === 'number' ? Number(event.target.value) : event.target.value)}
      />
      {description ? <FieldDescription>{description}</FieldDescription> : null}
    </Field>
  )
}

function Panel({ title, children, footer }: { title: string; children: React.ReactNode; footer?: React.ReactNode }) {
  return (
    <Card className="w-full rounded-none border-border/70 bg-background/90 backdrop-blur">
      <CardHeader>
        <CardTitle>{title}</CardTitle>
      </CardHeader>
      <CardContent className="flex flex-col gap-6">
        {children}
        {footer ? (
          <div className="flex flex-wrap items-center gap-3 border-t border-border/70 pt-5">{footer}</div>
        ) : null}
      </CardContent>
    </Card>
  )
}

function InfoAlert({ title, children }: { title: string; children: React.ReactNode }) {
  return (
    <Alert>
      <AlertTitle>{title}</AlertTitle>
      <AlertDescription>{children}</AlertDescription>
    </Alert>
  )
}

function ErrorAlert({ error }: { error?: unknown }) {
  const { t } = useTranslation()
  if (!error) return null

  return (
    <Alert variant="destructive">
      <AlertTitle>{t('setup.errors.generic_title')}</AlertTitle>
      <AlertDescription>
        <pre className="whitespace-pre-wrap text-xs">{errorMessage(error)}</pre>
      </AlertDescription>
    </Alert>
  )
}

function defaultConfigForAdapter(adapter: AdapterDescriptor | undefined): PluginConfigJsonObject {
  return defaultPluginConfigForSetup(adapter?.setup)
}

function errorMessage(error: unknown): string {
  return apiErrorMessage(error)
}

function localizedText(value: LocalizedText | undefined, locale: string): string | undefined {
  /*
   * Setup and console must resolve plugin-owned adapter text the same way. The
   * helper lives in the SDK so plugin authors can rely on one fallback order
   * across first-run setup and later console CRUD screens.
   */
  return resolveBullXPluginLocalizedText(value, locale)
}

function uniqueStrings(values: string[]): string[] {
  return [...new Set(values.filter(Boolean))]
}
