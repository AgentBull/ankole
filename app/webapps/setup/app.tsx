import { uniq } from '@agentbull/active-support'
import { revalidateLogic, useForm } from '@tanstack/react-form'
import {
  RiArrowRightSLine,
  RiCheckLine,
  RiFileCopyLine,
  RiLoaderLine,
  RiLock2Line,
  RiLoginCircleLine
} from '@remixicon/react'
import { Button } from '@ankole/uikit/components/button'
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
import { RadioGroup, RadioGroupItem } from '@ankole/uikit/components/radio-group'
import { Select, SelectContent, SelectItem, SelectTrigger, SelectValue } from '@ankole/uikit/components/select'
import { toast } from '@ankole/uikit/components/sonner'
import { useModel } from '@preact/signals-react'
import { useSignals } from '@preact/signals-react/runtime'
import { useIsMutating, useMutation, useQuery, useQueryClient } from '@tanstack/react-query'
import { useEffect, useId, useMemo, useState } from 'react'
import { useTranslation } from 'react-i18next'
import { z } from 'zod'
import {
  setupState,
  createSetupSession,
  logSetupActivationCode,
  setupPlugins,
  updateSetupPlugins,
  setupIdentityProviderAdapters,
  putSetupIdentityProvider,
  setupOidcAuthorization
} from '../common/api/generated/sdk.gen'
import type {
  SetupStateResponse as SetupState,
  SetupIdentityProviderAdaptersResponse
} from '../common/api/generated/types.gen'
export type IdentityAdapter = SetupIdentityProviderAdaptersResponse['adapters'][number]
import { ConfigFields, defaultConfig, localizedText, setPath } from '../common/config-fields'
import { ErrorBlock } from '../common/error-block'
import i18n, { loadLocale, nativeLocaleLabel } from '../common/i18n'
import { BrainPacksStep } from './brain-packs-step'
import { SetupLayout, SetupPanel } from './layout'
import { EmailAdminForm } from './email-admin-form'
import { IdentitySetupModel, type IdentitySetupDraft } from './state/identity-setup-model'
import { PluginsStepModel, filterSelectedPluginItems } from './state/plugins-step-model'
import { setupStepState, type SetupStepID } from './state/setup-progress'

const bootstrapSchema = z.object({
  activation_code: z.string().min(1, {
    error: () => i18n.t('common.field_required', { field: i18n.t('setup.activation_code') })
  }),
  locale: z.string().min(1)
})

type BootstrapInput = z.infer<typeof bootstrapSchema>

const providerIDPattern = /^[a-z][a-z0-9_-]*$/

function identitySchema(adapterRequired: string, providerIDInvalid: string) {
  return z.object({
    adapterID: z.string().min(1, { error: adapterRequired }),
    providerID: z.string().regex(providerIDPattern, { error: providerIDInvalid })
  })
}

export function SetupApp() {
  const queryClient = useQueryClient()
  const pending = useIsMutating() > 0
  const { t } = useTranslation()
  useEffect(() => {
    document.title = t('setup.document_title')
  }, [t])
  const pluginsModel = useModel(PluginsStepModel)
  const identityModel = useModel(IdentitySetupModel)
  // A reload restarts at the plugin step. The selected plugins live only in
  // this model, and the identity step reads them to know which adapters to
  // offer, so restoring the step alone would land the operator on a screen
  // that reports no adapters at all.
  const [step, setStep] = useState<'plugins' | 'industry' | 'identity'>('plugins')
  const [completedSteps, setCompletedSteps] = useState<ReadonlySet<SetupStepID>>(new Set())
  const completeStep = (completed: SetupStepID, next: 'industry' | 'identity') => {
    setCompletedSteps(current => new Set([...current, completed]))
    setStep(next)
  }
  const state = useQuery({
    queryKey: ['setup-state'],
    queryFn: () => setupState()
  })

  useEffect(() => {
    // The server owns the selected locale. The SPA mirrors it after loading
    // setup state so client text stays aligned with the Phoenix shell. The
    // catalog must load first, or i18next falls back to en-US for good.
    const locale = state.data?.currentLocale
    if (locale) void loadLocale(locale).then(() => i18n.changeLanguage(locale))
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
    { id: 'industry', label: t('setup.step_industry') },
    { id: 'identity', label: t('setup.step_identity') }
  ]

  return (
    <SetupLayout>
      <fieldset
        disabled={pending}
        inert={pending}
        className="grid flex-1 grid-cols-1 gap-6 py-8 lg:grid-cols-[220px_minmax(0,1fr)]">
        <nav className="h-fit border border-border bg-background/95 p-3 backdrop-blur" aria-label={t('setup.steps')}>
          <ol className="flex flex-row gap-2 overflow-x-auto lg:flex-col lg:overflow-visible">
            {steps.map((item, index) => {
              const itemState = setupStepState(item.id, currentStep, authenticated, completedSteps)
              const locked = itemState === 'locked'
              const navigable = authenticated && item.id !== 'bootstrap' && !locked
              return (
                <li key={item.id} className="min-w-28 lg:min-w-0">
                  <button
                    type="button"
                    aria-current={itemState === 'current' ? 'step' : undefined}
                    disabled={!navigable}
                    onClick={() => item.id !== 'bootstrap' && setStep(item.id)}
                    className={`flex min-h-12 w-full items-center gap-3 border px-3 text-left text-sm transition-colors focus-visible:-outline-offset-2 disabled:cursor-default ${
                      itemState === 'current'
                        ? 'border-foreground bg-accent text-foreground'
                        : itemState === 'completed' || itemState === 'available'
                          ? 'border-transparent text-foreground'
                          : 'border-transparent text-muted-foreground opacity-55'
                    }`}>
                    <span
                      className={`grid size-7 shrink-0 place-items-center border font-mono text-xs ${
                        itemState === 'current' ? 'border-foreground bg-foreground text-background' : 'border-border'
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
            <SetupPanel title={t('setup.title')}>
              <ErrorBlock
                error={state.error}
                action={
                  <Button size="sm" type="button" variant="outline" onClick={() => void state.refetch()}>
                    {t('common.retry')}
                  </Button>
                }
              />
            </SetupPanel>
          ) : state.isLoading ? (
            <SetupPanel title={t('setup.title')}>{t('common.loading')}</SetupPanel>
          ) : !authenticated ? (
            <BootstrapGate
              setupState={state.data}
              onAuthenticated={() => queryClient.invalidateQueries({ queryKey: ['setup-state'] })}
            />
          ) : step === 'plugins' ? (
            <PluginsStep model={pluginsModel} onContinue={() => completeStep('plugins', 'industry')} />
          ) : step === 'industry' ? (
            <BrainPacksStep onContinue={() => completeStep('industry', 'identity')} />
          ) : (
            <IdentityStep
              model={identityModel}
              pluginsModel={pluginsModel}
              publicBaseURL={state.data?.publicBaseURL ?? window.location.origin}
            />
          )}
        </div>
      </fieldset>
    </SetupLayout>
  )
}

function BootstrapGate({ setupState, onAuthenticated }: { setupState?: SetupState; onAuthenticated: () => void }) {
  const { t } = useTranslation()
  const locale = setupState?.currentLocale ?? i18n.language
  const mutation = useMutation({
    mutationFn: (input: BootstrapInput) => createSetupSession({ body: { data: input } }),
    onSuccess: onAuthenticated
  })
  const form = useForm({
    defaultValues: { activation_code: '', locale },
    validationLogic: revalidateLogic(),
    validators: { onDynamic: bootstrapSchema },
    onSubmit: ({ value }) => {
      mutation.mutate(value)
    }
  })
  const printActivationCode = useMutation({
    mutationFn: () => logSetupActivationCode(),
    onSuccess: () => toast.success(t('setup.activation_printed'))
  })
  const availableLocales = useMemo(
    // Include the current locale even if catalog reload state is temporarily
    // behind AppConfigure. This avoids rendering an empty selected option.
    () => uniq([...(setupState?.availableLocales ?? []), locale].filter(Boolean)),
    [locale, setupState?.availableLocales]
  )

  return (
    <SetupPanel title={t('setup.bootstrap_title')}>
      <p className="text-sm leading-6 text-muted-foreground">{t('setup.activation_hint')}</p>
      <ErrorBlock error={mutation.error ?? printActivationCode.error} />
      <form
        className="grid gap-6"
        noValidate
        onSubmit={event => {
          event.preventDefault()
          event.stopPropagation()
          void form.handleSubmit()
        }}>
        <FieldGroup className="grid grid-cols-1 gap-5 md:grid-cols-2">
          <form.Field name="locale">
            {field => (
              <Field>
                <FieldLabel>{t('setup.language')}</FieldLabel>
                <Select
                  value={field.state.value || locale}
                  onValueChange={value => {
                    if (!value) return
                    field.handleChange(value)
                    void loadLocale(value).then(() => {
                      if (form.getFieldValue('locale') === value) void i18n.changeLanguage(value)
                    })
                  }}>
                  <SelectTrigger className="w-full">
                    <SelectValue />
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
          </form.Field>

          <form.Field name="activation_code">
            {field => {
              const error = field.state.meta.errors[0]?.message
              return (
                <Field>
                  <div className="flex flex-wrap items-center gap-2">
                    <FieldLabel>{t('setup.activation_code')}</FieldLabel>
                    <button
                      className="link text-sm leading-5 disabled:cursor-not-allowed disabled:opacity-60"
                      disabled={printActivationCode.isPending}
                      onClick={() => printActivationCode.mutate()}
                      type="button">
                      {printActivationCode.isPending ? t('setup.activation_printing') : t('setup.activation_print')}
                    </button>
                  </div>
                  <Input
                    aria-invalid={error ? true : undefined}
                    autoComplete="one-time-code"
                    name={field.name}
                    value={field.state.value}
                    onBlur={field.handleBlur}
                    onChange={event => field.handleChange(event.target.value.toUpperCase())}
                  />
                  {error ? <UiFieldError>{error}</UiFieldError> : null}
                </Field>
              )
            }}
          </form.Field>
        </FieldGroup>

        <div className="flex flex-wrap items-center gap-3 border-t border-border/70 pt-5">
          <Button aria-busy={mutation.isPending} disabled={mutation.isPending} type="submit">
            {t('common.continue')}
            {mutation.isPending ? (
              <RiLoaderLine aria-hidden className="animate-spin" data-icon="inline-end" />
            ) : (
              <RiArrowRightSLine data-icon="inline-end" />
            )}
          </Button>
        </div>
      </form>
    </SetupPanel>
  )
}

function PluginsStep({ model, onContinue }: { model: InstanceType<typeof PluginsStepModel>; onContinue: () => void }) {
  'use no memo'

  useSignals()
  const { i18n: i18next, t } = useTranslation()
  const query = useQuery({
    queryKey: ['setup-plugins'],
    queryFn: () => setupPlugins()
  })

  useEffect(() => {
    if (query.data) model.initialize('setup-plugins', query.data.enabledPluginIDs)
  }, [model, query.data])

  // The effect seeds the model after paint, so the frame that first carries
  // `query.data` reads the server selection directly — otherwise every
  // already-enabled plugin would flash unchecked once.
  const seeded = model.sourceKey.value === 'setup-plugins'
  const selectedIDs: ReadonlySet<string> = seeded
    ? model.selectedPluginIDs.value
    : new Set(query.data?.enabledPluginIDs ?? [])
  const mutation = useMutation({
    mutationFn: () => updateSetupPlugins({ body: { data: model.submission() } }),
    onSuccess: onContinue
  })

  return (
    <SetupPanel title={t('setup.choose_plugins')}>
      <p className="text-sm leading-6 text-muted-foreground">{t('setup.plugin_restart_note')}</p>
      <ErrorBlock error={query.error ?? mutation.error} />
      <div className="grid grid-cols-1 gap-3 xl:grid-cols-2">
        {(query.data?.plugins ?? []).map(plugin => {
          const checked = selectedIDs.has(plugin.id)

          return (
            <label key={plugin.id} className="flex items-start gap-3 border border-border/70 bg-card/60 px-4 py-4">
              <Checkbox
                disabled={mutation.isPending || plugin.activation === 'always'}
                checked={checked}
                onCheckedChange={value => model.setPluginSelected(plugin.id, value === true)}
              />
              <span className="grid min-w-0 flex-1 gap-2">
                <span className="break-words text-sm font-semibold leading-5">
                  {localizedText(plugin.displayName, i18next.language) ?? plugin.id}
                </span>
                {plugin.activation === 'always' && (
                  <span className="text-xs text-muted-foreground">
                    {t('console.agent_library_capabilities.always_active')}
                  </span>
                )}
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
    </SetupPanel>
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
  const { t } = useTranslation()
  const query = useQuery({
    queryKey: ['setup-identity-provider-adapters'],
    queryFn: () => setupIdentityProviderAdapters()
  })
  const adapters = filterSelectedPluginItems(query.data?.adapters ?? [], pluginsModel.selectedPluginIDs.value)

  if (query.isLoading) return <SetupPanel title={t('setup.identity_provider')}>{t('common.loading')}</SetupPanel>

  return <IdentityMethodStep adapters={adapters} model={model} publicBaseURL={publicBaseURL} />
}

/**
 * Sign-in method chooser for SMTP verification and enterprise SSO. The chosen adapter's form renders below.
 */
function IdentityMethodStep({
  adapters,
  model,
  publicBaseURL
}: {
  adapters: IdentityAdapter[]
  model: InstanceType<typeof IdentitySetupModel>
  publicBaseURL: string
}) {
  'use no memo'

  useSignals()
  const { i18n: i18next, t } = useTranslation()
  const firstAdapter = adapters[0]
  const emailMethod = model.adapterID.value === 'email_otp' || !firstAdapter

  useEffect(() => {
    if (!firstAdapter) return
    const initialDraft = {
      adapterID: firstAdapter.adapterID,
      providerID: firstAdapter.defaultProviderID,
      config: defaultConfig(firstAdapter.fields)
    }
    model.initialize('setup-identity', initialDraft)

    if (
      model.adapterID.value !== 'email_otp' &&
      !adapters.some(adapter => adapter.adapterID === model.adapterID.value)
    ) {
      model.changeAdapter(initialDraft)
    }
  }, [adapters, firstAdapter, model])

  const activeAdapter = adapters.find(adapter => adapter.adapterID === model.adapterID.value) ?? firstAdapter

  function changeAdapter(nextAdapterID: string) {
    if (nextAdapterID === 'email_otp') {
      model.changeAdapter({ adapterID: 'email_otp', providerID: '', config: {} })
      return
    }
    if (nextAdapterID === activeAdapter?.adapterID) return
    const nextAdapter = adapters.find(adapter => adapter.adapterID === nextAdapterID) ?? firstAdapter
    // Switching adapters resets generated config because field paths and default
    // values are adapter-owned. Preserving old config would mix provider contracts.
    model.changeAdapter({
      adapterID: nextAdapter.adapterID,
      providerID: nextAdapter.defaultProviderID,
      config: defaultConfig(nextAdapter.fields)
    })
  }

  return (
    <SetupPanel title={t('setup.identity_provider')}>
      <p className="text-sm leading-6 text-muted-foreground">{t('setup.identity_intro')}</p>
      <section className="grid gap-4">
        <h2 className="text-sm font-semibold uppercase tracking-normal text-muted-foreground">
          {t('setup.sign_in_method')}
        </h2>
        <RadioGroup
          aria-label={t('setup.sign_in_method')}
          className="grid grid-cols-1 gap-3 xl:grid-cols-2"
          value={emailMethod ? 'email_otp' : activeAdapter.adapterID}
          onValueChange={value => {
            if (typeof value === 'string') changeAdapter(value)
          }}>
          <label className="flex cursor-pointer items-start gap-3 border border-border p-4">
            <RadioGroupItem value="email_otp" />
            <span>
              <strong>{t('setup.email_method')}</strong>
              <p>{t('setup.email_method_hint')}</p>
            </span>
          </label>
          {adapters.map(adapter => {
            const selected = !emailMethod && adapter.adapterID === activeAdapter?.adapterID
            const label = identityAdapterLabel(adapter, i18next.language)
            return (
              <label
                key={adapter.adapterID}
                className={`flex cursor-pointer items-start gap-3 border px-4 py-4 transition-colors ${
                  selected ? 'border-foreground bg-card' : 'border-border/70 bg-card/60'
                }`}>
                <RadioGroupItem className="mt-0.5" value={adapter.adapterID} />
                <span className="grid min-w-0 flex-1 gap-1">
                  <span className="break-words text-sm font-semibold leading-5">{label}</span>
                  <span className="break-words text-xs leading-5 text-muted-foreground">
                    {t('setup.method_sso_hint', { provider: label })}
                  </span>
                </span>
              </label>
            )
          })}
        </RadioGroup>
      </section>
      {emailMethod ? (
        <EmailAdminForm />
      ) : (
        // The key remounts the form per adapter so request state from one
        // provider never lingers under another.
        <SSOIdentityForm
          key={activeAdapter.adapterID}
          adapter={activeAdapter}
          model={model}
          publicBaseURL={publicBaseURL}
        />
      )}
    </SetupPanel>
  )
}

/** Renders the selected SSO adapter fields and starts setup-time OIDC. */
function SSOIdentityForm({
  adapter: activeAdapter,
  model,
  publicBaseURL
}: {
  adapter: IdentityAdapter
  model: InstanceType<typeof IdentitySetupModel>
  publicBaseURL: string
}) {
  useSignals()
  const { i18n: i18next, t } = useTranslation()
  const [callbackCopied, setCallbackCopied] = useState(false)
  const providerIDControlID = useId()
  const providerIDErrorID = `${providerIDControlID}-error`
  const providerIDHintID = `${providerIDControlID}-hint`

  const mutation = useMutation({
    mutationFn: async (input: IdentitySetupDraft) => {
      await putSetupIdentityProvider({
        path: { provider_id: input.providerID },
        body: {
          data: {
            adapterID: input.adapterID,
            config: setPath(input.config, 'oidc.enabled', true),
            enabled: true
          }
        }
      })
      return setupOidcAuthorization({ path: { provider_id: input.providerID } })
    },
    onSuccess: result => window.location.assign(result.authorizationURL)
  })

  function submitIdentity(event: React.FormEvent<HTMLFormElement>) {
    event.preventDefault()
    if (mutation.isPending) return
    const draft = model.submission()
    const result = identitySchema(t('setup.adapter_required'), t('setup.provider_id_invalid')).safeParse(draft)
    if (!result.success) {
      model.setValidationError(result.error.issues[0]?.message)
      return
    }

    model.setValidationError()
    mutation.mutate({ ...draft, ...result.data })
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
    <>
      <ErrorBlock error={mutation.error} />
      <form className="grid gap-6" onSubmit={submitIdentity}>
        <FieldGroup className="grid grid-cols-1 gap-5 md:grid-cols-2">
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
          <div className="flex flex-wrap items-center gap-x-4 gap-y-1">
            <FieldDescription id="oidc-callback-url-hint">
              {t(oidcCallbackURLHintKey(activeAdapter.adapterID))}
            </FieldDescription>
            <a
              className="link inline-flex items-center gap-1 text-sm font-medium"
              href={identityAdapterGuideURL(activeAdapter.adapterID, i18next.language)}
              rel="noopener noreferrer"
              target="_blank">
              {t('setup.adapter_guide')}
              <RiArrowRightSLine aria-hidden data-icon="inline-end" />
            </a>
          </div>
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
    </>
  )
}

/** Mirrors the host OIDC callback route, which the provider must have registered. */
function oidcCallbackURL(publicBaseURL: string, providerID: string): string {
  return `${publicBaseURL.replace(/\/$/, '')}/sessions/oidc/${encodeURIComponent(providerID)}/callback`
}

function identityAdapterGuideURL(adapterID: string, locale: string): string {
  const docsLocale = locale.startsWith('zh') ? 'zh-Hans-CN' : 'en-US'
  return `https://ankole.agentbull.com/${docsLocale}/docs/quickstart/?idp=${encodeURIComponent(adapterID)}#identity-providers`
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
    case 'wecom':
      return 'setup.oidc_callback_url_hint_wecom'
    default:
      return 'setup.oidc_callback_url_hint'
  }
}

function identityAdapterLabel(adapter: IdentityAdapter, locale: string): string {
  return localizedText(adapter.displayName, locale) ?? adapter.adapterID
}
