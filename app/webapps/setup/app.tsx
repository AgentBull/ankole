import { Field as FormField, Form, useForm } from '@formisch/react'
import {
  RiArrowRightSLine,
  RiCheckLine,
  RiFileCopyLine,
  RiLoaderLine,
  RiLock2Line,
  RiLoginCircleLine
} from '@remixicon/react'
import { Alert, AlertDescription, AlertTitle } from '@ankole/uikit/components/alert'
import { Button } from '@ankole/uikit/components/button'
import { Card, CardContent, CardHeader, CardTitle } from '@ankole/uikit/components/card'
import { Checkbox } from '@ankole/uikit/components/checkbox'
import {
  Field,
  FieldDescription,
  FieldGroup,
  FieldLabel,
  FieldTitle,
  FieldError as UiFieldError
} from '@ankole/uikit/components/field'
import { Input } from '@ankole/uikit/components/input'
import { Select, SelectContent, SelectItem, SelectTrigger, SelectValue } from '@ankole/uikit/components/select'
import { toast } from '@ankole/uikit/components/sonner'
import { useModel } from '@preact/signals-react'
import { useSignals } from '@preact/signals-react/runtime'
import { useMutation, useQuery, useQueryClient } from '@tanstack/react-query'
import { useEffect, useId, useMemo, useState, type ReactNode } from 'react'
import { useTranslation } from 'react-i18next'
import * as v from 'valibot'
import { internalAPIGet, internalAPIPost, internalAPIPut } from '../common/internal-api-client'
import {
  ConfigFields,
  defaultConfig,
  localizedText,
  setPath,
  type ConfigFieldDefinition,
  type LocalizedText
} from '../common/config-fields'
import i18n, { nativeLocaleLabel } from '../common/i18n'
import { requestErrorMessage } from '../common/request-errors'
import { SetupLayout } from './layout'
import { IdentitySetupModel, type IdentitySetupDraft } from './state/identity-setup-model'
import { filterSelectedPluginItems, PluginsStepModel } from './state/plugins-step-model'
import { setupStepState, type SetupStepID } from './state/setup-progress'

type SetupState = {
  authenticated: boolean
  availableLocales: string[]
  completed: boolean
  currentLocale: string
  publicBaseURL: string
}

type Plugin = {
  id: string
  displayName?: LocalizedText
  description?: LocalizedText
}

type SetupField = ConfigFieldDefinition

type IdentityAdapter = {
  adapterID: string
  defaultProviderID: string
  displayName?: LocalizedText
  fields: SetupField[]
  pluginID: string
}

const BootstrapSchema = v.object({
  activationCode: v.pipe(v.string(), v.nonEmpty('Activation code is required.')),
  locale: v.pipe(v.string(), v.nonEmpty())
})

const providerIDPattern = /^[a-z][a-z0-9_-]*$/

function identitySchema(adapterRequired: string, providerIDInvalid: string) {
  return v.object({
    adapterID: v.pipe(v.string(), v.nonEmpty(adapterRequired)),
    providerID: v.pipe(v.string(), v.regex(providerIDPattern, providerIDInvalid))
  })
}

/** Renders the setup SPA and switches between bootstrap, plugin, and identity steps. */
export function SetupApp() {
  const queryClient = useQueryClient()
  const { t } = useTranslation()
  const pluginsModel = useModel(PluginsStepModel)
  const identityModel = useModel(IdentitySetupModel)
  const [step, setStep] = useState<'plugins' | 'identity'>('plugins')
  const [pluginsCompleted, setPluginsCompleted] = useState(false)
  const state = useQuery({
    queryKey: ['setup-state'],
    queryFn: () => internalAPIGet<SetupState>('/.internal-apis/setup/state')
  })

  useEffect(() => {
    // The server owns the selected locale. The SPA mirrors it after loading
    // setup state so client text stays aligned with the Phoenix shell.
    if (state.data?.currentLocale) void i18n.changeLanguage(state.data.currentLocale)
  }, [state.data?.currentLocale])

  useEffect(() => {
    if (state.data?.completed) window.location.assign('/')
  }, [state.data?.completed])

  if (state.data?.completed) {
    return null
  }

  const authenticated = Boolean(state.data?.authenticated)
  const currentStep: SetupStepID = authenticated ? step : 'bootstrap'
  const steps: Array<{ id: SetupStepID; label: string }> = [
    { id: 'bootstrap', label: t('setup.step_bootstrap') },
    { id: 'plugins', label: t('setup.step_plugins') },
    { id: 'identity', label: t('setup.step_identity') }
  ]

  return (
    <SetupLayout>
      <section className="grid flex-1 grid-cols-1 gap-6 py-8 lg:grid-cols-[220px_minmax(0,1fr)]">
        <nav className="h-fit border border-border bg-background/95 p-3 backdrop-blur" aria-label={t('setup.steps')}>
          <ol className="flex flex-row gap-2 overflow-x-auto lg:flex-col lg:overflow-visible">
            {steps.map((item, index) => {
              const itemState = setupStepState(item.id, currentStep, authenticated, pluginsCompleted)
              const locked = itemState === 'locked'
              const navigable = authenticated && item.id !== 'bootstrap' && !locked
              return (
                <li key={item.id} className="min-w-28 lg:min-w-0">
                  <button
                    type="button"
                    aria-current={itemState === 'current' ? 'step' : undefined}
                    disabled={!navigable}
                    onClick={() => item.id !== 'bootstrap' && setStep(item.id)}
                    className={`flex min-h-12 w-full items-center gap-3 border px-3 text-left text-sm outline-none transition-colors focus-visible:ring-2 focus-visible:ring-ring/40 disabled:cursor-default ${
                      itemState === 'current'
                        ? 'border-primary bg-primary/10 text-foreground'
                        : itemState === 'completed' || itemState === 'available'
                          ? 'border-transparent text-foreground'
                          : 'border-transparent text-muted-foreground opacity-55'
                    }`}>
                    <span
                      className={`grid size-7 shrink-0 place-items-center border font-mono text-xs ${
                        itemState === 'current' ? 'border-primary bg-primary text-primary-foreground' : 'border-border'
                      }`}>
                      {itemState === 'completed' ? (
                        <RiCheckLine aria-hidden />
                      ) : itemState === 'locked' ? (
                        <RiLock2Line aria-hidden />
                      ) : (
                        String(index + 1).padStart(2, '0')
                      )}
                    </span>
                    <span className="grid min-w-0 gap-0.5">
                      <span className="truncate font-medium">{item.label}</span>
                      <span className="truncate text-xs text-muted-foreground">
                        {t(`setup.step_state_${itemState}`)}
                      </span>
                    </span>
                  </button>
                </li>
              )
            })}
          </ol>
        </nav>

        <div className="min-w-0">
          {state.error ? (
            <Panel title={t('setup.title')}>
              <ErrorAlert
                error={state.error}
                action={
                  <Button size="sm" type="button" variant="outline" onClick={() => void state.refetch()}>
                    {t('common.retry')}
                  </Button>
                }
              />
            </Panel>
          ) : state.isLoading ? (
            <Panel title={t('setup.title')}>{t('common.loading')}</Panel>
          ) : !authenticated ? (
            <BootstrapGate
              setupState={state.data}
              onAuthenticated={() => queryClient.invalidateQueries({ queryKey: ['setup-state'] })}
            />
          ) : step === 'plugins' ? (
            <PluginsStep
              model={pluginsModel}
              onContinue={() => {
                setPluginsCompleted(true)
                setStep('identity')
              }}
            />
          ) : (
            <IdentityStep
              model={identityModel}
              pluginsModel={pluginsModel}
              publicBaseURL={state.data?.publicBaseURL ?? window.location.origin}
            />
          )}
        </div>
      </section>
    </SetupLayout>
  )
}

function BootstrapGate({ setupState, onAuthenticated }: { setupState?: SetupState; onAuthenticated: () => void }) {
  const { t } = useTranslation()
  const locale = setupState?.currentLocale ?? i18n.language
  const form = useForm({
    schema: BootstrapSchema,
    initialInput: { activationCode: '', locale },
    validate: 'submit',
    revalidate: 'input'
  })
  const mutation = useMutation({
    mutationFn: (input: v.InferOutput<typeof BootstrapSchema>) =>
      internalAPIPost<{ ok: true }>('/.internal-apis/setup/sessions', input),
    onSuccess: onAuthenticated
  })
  const printActivationCode = useMutation({
    mutationFn: () => internalAPIPost<{ ok: true }>('/.internal-apis/setup/bootstrap-activation-code/log-entries'),
    onSuccess: () => toast.success(t('setup.activation_printed'))
  })
  const availableLocales = useMemo(
    // Include the current locale even if catalog reload state is temporarily
    // behind AppConfigure. This avoids rendering an empty selected option.
    () => unique([...(setupState?.availableLocales ?? []), locale]),
    [locale, setupState?.availableLocales]
  )

  return (
    <Panel title={t('setup.bootstrap_title')}>
      <p className="text-sm leading-6 text-muted-foreground">{t('setup.activation_hint')}</p>
      <ErrorAlert error={mutation.error ?? printActivationCode.error} />
      <Form className="grid gap-6" of={form} onSubmit={output => mutation.mutate(output)}>
        <FieldGroup className="grid grid-cols-1 gap-5 md:grid-cols-2">
          <FormField of={form} path={['locale']}>
            {field => (
              <Field>
                <FieldLabel>{t('setup.language')}</FieldLabel>
                <Select
                  value={String(field.input ?? locale)}
                  onValueChange={value => {
                    if (!value) return
                    field.onChange(value)
                    void i18n.changeLanguage(value)
                  }}>
                  <SelectTrigger className="w-full">
                    <SelectValue>{value => nativeLocaleLabel(value ?? locale)}</SelectValue>
                  </SelectTrigger>
                  <SelectContent>
                    {availableLocales.map(option => (
                      <SelectItem key={option} value={option}>
                        {nativeLocaleLabel(option)}
                      </SelectItem>
                    ))}
                  </SelectContent>
                </Select>
              </Field>
            )}
          </FormField>

          <FormField of={form} path={['activationCode']}>
            {field => (
              <Field>
                <div className="flex flex-wrap items-center gap-2">
                  <FieldLabel>{t('setup.activation_code')}</FieldLabel>
                  <button
                    className="text-sm leading-5 text-link underline underline-offset-4 hover:text-link/80 focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-ring/30 disabled:cursor-not-allowed disabled:opacity-60"
                    disabled={printActivationCode.isPending}
                    onClick={() => printActivationCode.mutate()}
                    type="button">
                    {printActivationCode.isPending ? t('setup.activation_printing') : t('setup.activation_print')}
                  </button>
                </div>
                <Input
                  {...field.props}
                  aria-invalid={field.errors ? true : undefined}
                  autoComplete="one-time-code"
                  value={String(field.input ?? '')}
                  onChange={event => field.onChange(event.target.value.toUpperCase())}
                />
                <FormFieldError errors={field.errors} />
              </Field>
            )}
          </FormField>
        </FieldGroup>

        <div className="flex flex-wrap items-center gap-3 border-t border-border/70 pt-5">
          <Button disabled={mutation.isPending} type="submit">
            {t('common.continue')}
            <RiArrowRightSLine data-icon="inline-end" />
          </Button>
        </div>
      </Form>
    </Panel>
  )
}

function PluginsStep({ model, onContinue }: { model: InstanceType<typeof PluginsStepModel>; onContinue: () => void }) {
  useSignals()
  const { i18n: i18next, t } = useTranslation()
  const query = useQuery({
    queryKey: ['setup-plugins'],
    queryFn: () => internalAPIGet<{ enabledPluginIDs: string[]; plugins: Plugin[] }>('/.internal-apis/setup/plugins')
  })

  useEffect(() => {
    if (query.data) model.initialize('setup-plugins', query.data.enabledPluginIDs)
  }, [model, query.data])

  const selectedIDs = model.selectedPluginIDs.value
  const mutation = useMutation({
    mutationFn: () =>
      internalAPIPut<{ enabledPluginIDs: string[] }>('/.internal-apis/setup/plugins/enabled', model.submission()),
    onSuccess: onContinue
  })

  return (
    <Panel title={t('setup.choose_plugins')}>
      <p className="text-sm leading-6 text-muted-foreground">{t('setup.plugin_restart_note')}</p>
      <ErrorAlert error={query.error ?? mutation.error} />
      <div className="grid grid-cols-1 gap-3 xl:grid-cols-2">
        {(query.data?.plugins ?? []).map(plugin => {
          const checked = selectedIDs.has(plugin.id)

          return (
            <label key={plugin.id} className="flex items-start gap-3 border border-border/70 bg-card/60 px-4 py-4">
              <Checkbox
                checked={checked}
                onCheckedChange={value => model.setPluginSelected(plugin.id, value === true)}
              />
              <span className="grid min-w-0 flex-1 gap-2">
                <span className="break-words text-sm font-semibold leading-5">
                  {localizedText(plugin.displayName, i18next.language) ?? plugin.id}
                </span>
                {plugin.description ? (
                  <span className="whitespace-pre-wrap break-words text-xs leading-5 text-muted-foreground">
                    {localizedText(plugin.description, i18next.language)}
                  </span>
                ) : null}
              </span>
            </label>
          )
        })}
      </div>
      <div className="flex flex-wrap items-center gap-3 border-t border-border/70 pt-5">
        <Button disabled={!query.data || mutation.isPending} onClick={() => mutation.mutate()} type="button">
          {t('setup.save_plugins')}
          <RiArrowRightSLine data-icon="inline-end" />
        </Button>
      </div>
    </Panel>
  )
}

function IdentityStep({
  model,
  pluginsModel,
  publicBaseURL
}: {
  model: InstanceType<typeof IdentitySetupModel>
  pluginsModel: InstanceType<typeof PluginsStepModel>
  publicBaseURL: string
}) {
  useSignals()
  const query = useQuery({
    queryKey: ['setup-identity-provider-adapters'],
    queryFn: () => internalAPIGet<{ adapters: IdentityAdapter[] }>('/.internal-apis/setup/identity-provider-adapters')
  })
  const adapters = filterSelectedPluginItems(query.data?.adapters ?? [], pluginsModel.selectedPluginIDs.value)

  if (query.isLoading) return <Panel title="">{i18n.t('common.loading')}</Panel>
  if (adapters.length === 0) return <NoAdapters error={query.error} />

  return <IdentityForm adapters={adapters} model={model} publicBaseURL={publicBaseURL} />
}

/** Renders the selected identity adapter fields and starts setup-time OIDC. */
function IdentityForm({
  adapters,
  model,
  publicBaseURL
}: {
  adapters: IdentityAdapter[]
  model: InstanceType<typeof IdentitySetupModel>
  publicBaseURL: string
}) {
  useSignals()
  const { i18n: i18next, t } = useTranslation()
  const firstAdapter = adapters[0]
  const [callbackCopied, setCallbackCopied] = useState(false)
  const providerIDControlID = useId()
  const providerIDErrorID = `${providerIDControlID}-error`
  const providerIDHintID = `${providerIDControlID}-hint`

  useEffect(() => {
    const initialDraft = {
      adapterID: firstAdapter.adapterID,
      providerID: firstAdapter.defaultProviderID,
      config: defaultConfig(firstAdapter.fields)
    }
    model.initialize('setup-identity', initialDraft)

    if (!adapters.some(adapter => adapter.adapterID === model.adapterID.value)) {
      model.changeAdapter(initialDraft)
    }
  }, [adapters, firstAdapter, model])

  const activeAdapter = adapters.find(adapter => adapter.adapterID === model.adapterID.value) ?? firstAdapter
  const mutation = useMutation({
    mutationFn: async (input: IdentitySetupDraft) => {
      await internalAPIPut(`/.internal-apis/setup/identity-providers/${encodeURIComponent(input.providerID)}`, {
        adapterID: input.adapterID,
        config: setPath(input.config, 'oidc.enabled', true),
        enabled: true
      })
      return internalAPIPost<{ authorizationURL: string }>(
        `/.internal-apis/setup/identity-providers/${encodeURIComponent(input.providerID)}/oidc/authorizations`
      )
    },
    onSuccess: result => window.location.assign(result.authorizationURL)
  })

  function changeAdapter(nextAdapterID: string) {
    const nextAdapter = adapters.find(adapter => adapter.adapterID === nextAdapterID) ?? firstAdapter
    // Switching adapters resets generated config because field paths and default
    // values are adapter-owned. Preserving old config would mix provider contracts.
    mutation.reset()
    model.changeAdapter({
      adapterID: nextAdapter.adapterID,
      providerID: nextAdapter.defaultProviderID,
      config: defaultConfig(nextAdapter.fields)
    })
  }

  function submitIdentity(event: React.FormEvent<HTMLFormElement>) {
    event.preventDefault()
    const draft = model.submission()
    const result = v.safeParse(identitySchema(t('setup.adapter_required'), t('setup.provider_id_invalid')), draft)
    if (!result.success) {
      model.setValidationError(result.issues[0]?.message)
      return
    }

    model.setValidationError()
    mutation.mutate({ ...draft, ...result.output })
  }

  async function copyCallbackURL() {
    try {
      await navigator.clipboard.writeText(oidcCallbackURL(publicBaseURL, model.providerID.value))
      setCallbackCopied(true)
      toast.success(t('setup.oidc_callback_url_copied'))
      window.setTimeout(() => setCallbackCopied(false), 2000)
    } catch {
      toast.error(t('setup.oidc_callback_url_copy_failed'))
    }
  }

  return (
    <Panel title={t('setup.identity_provider')}>
      <ErrorAlert error={mutation.error} />
      <form className="grid gap-6" onSubmit={submitIdentity}>
        <FieldGroup className="grid grid-cols-1 gap-5 md:grid-cols-2">
          <Field>
            <FieldLabel>{t('setup.adapter')}</FieldLabel>
            <Select
              value={model.adapterID.value || activeAdapter.adapterID}
              onValueChange={value => {
                if (value) changeAdapter(value)
              }}>
              <SelectTrigger className="w-full">
                <SelectValue>
                  {value =>
                    identityAdapterLabel(adapterByID(adapters, value ?? activeAdapter.adapterID), i18next.language)
                  }
                </SelectValue>
              </SelectTrigger>
              <SelectContent>
                {adapters.map(adapter => (
                  <SelectItem key={adapter.adapterID} value={adapter.adapterID}>
                    {identityAdapterLabel(adapter, i18next.language)}
                  </SelectItem>
                ))}
              </SelectContent>
            </Select>
          </Field>

          <Field>
            <FieldLabel htmlFor={providerIDControlID}>
              {t('setup.provider_id')}
              <span className="ml-1 font-normal text-muted-foreground">{t('common.required')}</span>
            </FieldLabel>
            <Input
              id={providerIDControlID}
              aria-describedby={
                model.validationError.value ? `${providerIDHintID} ${providerIDErrorID}` : providerIDHintID
              }
              aria-invalid={model.validationError.value ? true : undefined}
              value={model.providerID.value}
              onChange={event => {
                mutation.reset()
                model.providerID.value = event.target.value
                setCallbackCopied(false)
                model.setValidationError()
              }}
            />
            <FieldDescription id={providerIDHintID}>{t('setup.provider_id_hint')}</FieldDescription>
            {model.validationError.value ? (
              <UiFieldError id={providerIDErrorID}>{model.validationError.value}</UiFieldError>
            ) : null}
          </Field>
        </FieldGroup>

        <Field aria-labelledby="oidc-callback-url-label" aria-describedby="oidc-callback-url-hint">
          <FieldTitle id="oidc-callback-url-label">{t('setup.oidc_callback_url')}</FieldTitle>
          <div className="flex min-w-0 flex-col gap-3 border border-border/70 bg-muted/30 p-3 sm:flex-row sm:items-center">
            <code className="min-w-0 flex-1 break-all font-mono text-sm leading-6">
              {oidcCallbackURL(publicBaseURL, model.providerID.value)}
            </code>
            <Button onClick={copyCallbackURL} size="sm" type="button" variant="outline">
              {callbackCopied ? t('setup.oidc_callback_url_copied') : t('setup.oidc_callback_url_copy')}
              {callbackCopied ? (
                <RiCheckLine aria-hidden data-icon="inline-end" />
              ) : (
                <RiFileCopyLine aria-hidden data-icon="inline-end" />
              )}
            </Button>
          </div>
          <FieldDescription id="oidc-callback-url-hint">
            {t(oidcCallbackURLHintKey(activeAdapter.adapterID))}
          </FieldDescription>
        </Field>

        <section className="grid gap-5">
          <h2 className="text-sm font-semibold uppercase tracking-normal text-muted-foreground">
            {t('setup.adapter_config')}
          </h2>
          <ConfigFields
            advancedLabel={t('setup.advanced_config')}
            config={model.config.value}
            fields={activeAdapter.fields.filter(field => field.path !== 'oidc.enabled')}
            locale={i18next.language}
            onChange={(path, value) => {
              mutation.reset()
              model.setConfig(setPath(model.config.value, path, value))
            }}
            showAdvancedCount={false}
          />
        </section>

        <div className="flex flex-wrap items-center gap-3 border-t border-border/70 pt-5">
          <Button aria-busy={mutation.isPending} disabled={mutation.isPending} type="submit">
            {mutation.isPending ? t('setup.validating_and_redirecting') : t('setup.complete_identity')}
            {mutation.isPending ? (
              <RiLoaderLine aria-hidden className="animate-spin" data-icon="inline-end" />
            ) : (
              <RiLoginCircleLine aria-hidden data-icon="inline-end" />
            )}
          </Button>
        </div>
      </form>
    </Panel>
  )
}

/** Shows the identity step when no enabled plugin contributes an adapter. */
function NoAdapters({ error }: { error: unknown }) {
  const { t } = useTranslation()

  return (
    <Panel title={t('setup.identity_provider')}>
      <p className="text-sm leading-6 text-muted-foreground">{t('setup.no_adapters')}</p>
      <ErrorAlert error={error} />
    </Panel>
  )
}

/** Mirrors the host OIDC callback route, which the provider must have registered. */
function oidcCallbackURL(publicBaseURL: string, providerID: string): string {
  return `${publicBaseURL.replace(/\/$/, '')}/sessions/oidc/${encodeURIComponent(providerID)}/callback`
}

function oidcCallbackURLHintKey(adapterID: string): string {
  switch (adapterID) {
    case 'dingtalk':
      return 'setup.oidc_callback_url_hint_dingtalk'
    case 'entra-id':
      return 'setup.oidc_callback_url_hint_entra'
    case 'google-workspace':
      return 'setup.oidc_callback_url_hint_google'
    case 'lark':
      return 'setup.oidc_callback_url_hint_lark'
    case 'slack':
      return 'setup.oidc_callback_url_hint_slack'
    default:
      return 'setup.oidc_callback_url_hint'
  }
}

function adapterByID(adapters: IdentityAdapter[], adapterID: string): IdentityAdapter {
  return adapters.find(adapter => adapter.adapterID === adapterID) ?? adapters[0]
}

function identityAdapterLabel(adapter: IdentityAdapter, locale: string): string {
  return localizedText(adapter.displayName, locale) ?? adapter.adapterID
}

/** Shared setup panel frame. */
function Panel({ children, title }: { children: ReactNode; title: string }) {
  return (
    <Card className="w-full rounded-none border-border/70 bg-background/90 backdrop-blur">
      <CardHeader>
        <CardTitle>{title}</CardTitle>
      </CardHeader>
      <CardContent className="flex flex-col gap-6">{children}</CardContent>
    </Card>
  )
}

/** Renders request failures in the setup flow without throwing from React. */
function ErrorAlert({ action, error }: { action?: ReactNode; error?: unknown }) {
  const { t } = useTranslation()
  if (!error) return null

  return (
    <Alert variant="destructive">
      <AlertTitle>{t('common.error')}</AlertTitle>
      <AlertDescription>
        <pre className="break-all whitespace-pre-wrap text-xs">{requestErrorMessage(error)}</pre>
        {action ? <div className="mt-3">{action}</div> : null}
      </AlertDescription>
    </Alert>
  )
}

/** Shows the first validation error from Formisch field state. */
function FormFieldError({ errors }: { errors: [string, ...string[]] | null }) {
  return errors ? <UiFieldError>{errors[0]}</UiFieldError> : null
}

/** Returns unique non-empty values while preserving user-visible order. */
function unique(values: string[]): string[] {
  return [...new Set(values.filter(Boolean))]
}
