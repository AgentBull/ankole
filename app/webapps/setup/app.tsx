import { Field as FormField, Form, setInput, useForm } from '@formisch/react'
import { RiArrowRightSLine, RiLoginCircleLine } from '@remixicon/react'
import { Alert, AlertDescription, AlertTitle } from '@ankole/uikit/components/alert'
import { Button } from '@ankole/uikit/components/button'
import { Card, CardContent, CardHeader, CardTitle } from '@ankole/uikit/components/card'
import { Checkbox } from '@ankole/uikit/components/checkbox'
import {
  Field,
  FieldDescription,
  FieldGroup,
  FieldLabel,
  FieldError as UiFieldError
} from '@ankole/uikit/components/field'
import { Input } from '@ankole/uikit/components/input'
import { Select, SelectContent, SelectItem, SelectTrigger, SelectValue } from '@ankole/uikit/components/select'
import { Textarea } from '@ankole/uikit/components/textarea'
import { useMutation, useQuery, useQueryClient } from '@tanstack/react-query'
import { useEffect, useMemo, useState, type ReactNode } from 'react'
import { useTranslation } from 'react-i18next'
import * as v from 'valibot'
import { apiErrorMessage, apiGet, apiPost, apiPut, type JsonObject, type JsonValue } from '../common/api'
import i18n, { nativeLocaleLabel } from '../common/i18n'
import { SetupLayout } from './layout'

type SetupState = {
  authenticated: boolean
  availableLocales: string[]
  completed: boolean
  currentLocale: string
}

type LocalizedText = string | Record<string, string> | null | undefined

type Plugin = {
  id: string
  displayName?: LocalizedText
  description?: LocalizedText
}

type SetupField = {
  default?: JsonValue
  description?: LocalizedText
  label?: LocalizedText
  max?: number
  min?: number
  options?: Array<string | { label?: LocalizedText; value: string }>
  path: string
  required?: boolean
  type: string
}

type IdentityAdapter = {
  adapterId: string
  defaultProviderId: string
  displayName?: LocalizedText
  fields: SetupField[]
  pluginId: string
}

const BootstrapSchema = v.object({
  activationCode: v.pipe(v.string(), v.nonEmpty('Activation code is required.')),
  locale: v.pipe(v.string(), v.nonEmpty())
})

const IdentitySchema = v.object({
  adapterId: v.pipe(v.string(), v.nonEmpty('Adapter is required.')),
  providerId: v.pipe(v.string(), v.regex(/^[a-z][a-z0-9_-]*$/, 'Use lowercase letters, numbers, _, or -.'))
})

/** Renders the setup SPA and switches between bootstrap, plugin, and identity steps. */
export function SetupApp() {
  const queryClient = useQueryClient()
  const { t } = useTranslation()
  const [step, setStep] = useState<'plugins' | 'identity'>('plugins')
  const state = useQuery({
    queryKey: ['setup-state'],
    queryFn: () => apiGet<SetupState>('/.internal-apis/setup/state')
  })

  useEffect(() => {
    // The server owns the selected locale. The SPA mirrors it after loading
    // setup state so client text stays aligned with the Phoenix shell.
    if (state.data?.currentLocale) void i18n.changeLanguage(state.data.currentLocale)
  }, [state.data?.currentLocale])

  if (state.data?.completed) {
    window.location.assign('/')
    return null
  }

  return (
    <SetupLayout>
      <section className="grid flex-1 grid-cols-1 gap-6 py-8 lg:grid-cols-[220px_minmax(0,1fr)]">
        <nav className="h-fit border border-border/70 bg-background/85 p-3 backdrop-blur" aria-label="Setup steps">
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
                  <span className="truncate">{t(id === 'plugins' ? 'setup.step_plugins' : 'setup.step_identity')}</span>
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
      apiPost<{ ok: true }>('/.internal-apis/setup/sessions', input),
    onSuccess: onAuthenticated
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
      <ErrorAlert error={mutation.error} />
      <Form className="grid gap-6" of={form} onSubmit={output => mutation.mutate(output)}>
        <FieldGroup className="grid gap-5 md:grid-cols-2">
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
                <FieldLabel>{t('setup.activation_code')}</FieldLabel>
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

function PluginsStep({ onContinue }: { onContinue: () => void }) {
  const { i18n: i18next, t } = useTranslation()
  const query = useQuery({
    queryKey: ['setup-plugins'],
    queryFn: () => apiGet<{ enabledPluginIds: string[]; plugins: Plugin[] }>('/.internal-apis/setup/plugins')
  })
  const [selected, setSelected] = useState<Set<string> | null>(null)
  // `null` means the user has not touched the form yet. Until then, the server
  // value remains the source of truth and late query data can still populate UI.
  const selectedIds = selected ?? new Set(query.data?.enabledPluginIds ?? [])
  const mutation = useMutation({
    mutationFn: () =>
      apiPut<{ enabledPluginIds: string[] }>('/.internal-apis/setup/plugins/enabled', { pluginIds: [...selectedIds] }),
    onSuccess: onContinue
  })

  return (
    <Panel title={t('setup.choose_plugins')}>
      <p className="text-sm leading-6 text-muted-foreground">{t('setup.plugin_restart_note')}</p>
      <ErrorAlert error={query.error ?? mutation.error} />
      <div className="grid gap-3 xl:grid-cols-2">
        {(query.data?.plugins ?? []).map(plugin => {
          const checked = selectedIds.has(plugin.id)

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

function IdentityStep() {
  const query = useQuery({
    queryKey: ['setup-identity-provider-adapters'],
    queryFn: () => apiGet<{ adapters: IdentityAdapter[] }>('/.internal-apis/setup/identity-provider-adapters')
  })

  if (query.isLoading) return <Panel title="">{i18n.t('common.loading')}</Panel>
  if ((query.data?.adapters ?? []).length === 0) return <NoAdapters error={query.error} />

  return <IdentityForm adapters={query.data?.adapters ?? []} />
}

/** Renders the selected identity adapter fields and starts setup-time OIDC. */
function IdentityForm({ adapters }: { adapters: IdentityAdapter[] }) {
  const { i18n: i18next, t } = useTranslation()
  const firstAdapter = adapters[0]
  const form = useForm({
    schema: IdentitySchema,
    initialInput: {
      adapterId: firstAdapter.adapterId,
      providerId: firstAdapter.defaultProviderId
    },
    validate: 'submit',
    revalidate: 'input'
  })
  const [adapterId, setAdapterId] = useState(firstAdapter.adapterId)
  const activeAdapter = adapters.find(adapter => adapter.adapterId === adapterId) ?? firstAdapter
  const [config, setConfig] = useState<JsonObject>(() => defaultConfig(activeAdapter.fields))
  const mutation = useMutation({
    mutationFn: async (input: v.InferOutput<typeof IdentitySchema>) => {
      await apiPut(`/.internal-apis/setup/identity-providers/${encodeURIComponent(input.providerId)}`, {
        adapter: input.adapterId,
        config,
        enabled: true
      })
      return apiPost<{ authorizationUrl: string }>(
        `/.internal-apis/setup/identity-providers/${encodeURIComponent(input.providerId)}/oidc/authorizations`
      )
    },
    onSuccess: result => window.location.assign(result.authorizationUrl)
  })

  function changeAdapter(nextAdapterId: string) {
    const nextAdapter = adapters.find(adapter => adapter.adapterId === nextAdapterId) ?? firstAdapter
    setAdapterId(nextAdapter.adapterId)
    // Switching adapters resets generated config because field paths and default
    // values are adapter-owned. Preserving old config would mix provider contracts.
    setConfig(defaultConfig(nextAdapter.fields))
    setInput(form, { path: ['adapterId'], input: nextAdapter.adapterId })
    setInput(form, { path: ['providerId'], input: nextAdapter.defaultProviderId })
  }

  return (
    <Panel title={t('setup.identity_provider')}>
      <ErrorAlert error={mutation.error} />
      <Form className="grid gap-6" of={form} onSubmit={output => mutation.mutate(output)}>
        <FieldGroup className="grid gap-5 md:grid-cols-2">
          <FormField of={form} path={['adapterId']}>
            {field => (
              <Field>
                <FieldLabel>{t('setup.adapter')}</FieldLabel>
                <Select
                  value={String(field.input ?? activeAdapter.adapterId)}
                  onValueChange={value => {
                    if (value) changeAdapter(value)
                  }}>
                  <SelectTrigger className="w-full">
                    <SelectValue />
                  </SelectTrigger>
                  <SelectContent>
                    {adapters.map(adapter => (
                      <SelectItem key={adapter.adapterId} value={adapter.adapterId}>
                        {localizedText(adapter.displayName, i18next.language) ?? adapter.adapterId}
                      </SelectItem>
                    ))}
                  </SelectContent>
                </Select>
                <FormFieldError errors={field.errors} />
              </Field>
            )}
          </FormField>

          <FormField of={form} path={['providerId']}>
            {field => (
              <Field>
                <FieldLabel>{t('setup.provider_id')}</FieldLabel>
                <Input
                  {...field.props}
                  aria-invalid={field.errors ? true : undefined}
                  value={String(field.input ?? '')}
                  onChange={event => field.onChange(event.target.value)}
                />
                <FieldDescription>{t('setup.provider_id_hint')}</FieldDescription>
                <FormFieldError errors={field.errors} />
              </Field>
            )}
          </FormField>
        </FieldGroup>

        <section className="grid gap-5">
          <h2 className="text-sm font-semibold uppercase tracking-normal text-muted-foreground">
            {t('setup.adapter_config')}
          </h2>
          <FieldGroup className="grid gap-5 md:grid-cols-2">
            {activeAdapter.fields.map(field => (
              <ConfigField
                field={field}
                key={field.path}
                locale={i18next.language}
                value={getPath(config, field.path)}
                onChange={value => setConfig(previous => setPath(previous, field.path, value))}
              />
            ))}
          </FieldGroup>
        </section>

        <div className="flex flex-wrap items-center gap-3 border-t border-border/70 pt-5">
          <Button disabled={mutation.isPending} type="submit">
            {t('setup.complete_with_oidc')}
            <RiLoginCircleLine data-icon="inline-end" />
          </Button>
        </div>
      </Form>
    </Panel>
  )
}

/** Renders one plugin-declared setup field into a JSON config value. */
function ConfigField({
  field,
  locale,
  onChange,
  value
}: {
  field: SetupField
  locale: string
  onChange(value: JsonValue): void
  value: JsonValue | undefined
}) {
  const label = localizedText(field.label, locale) ?? field.path
  const description = localizedText(field.description, locale)

  if (field.type === 'boolean') {
    return (
      <Field orientation="horizontal" className="items-center justify-between border border-border/70 bg-card/60 p-4">
        <div className="grid gap-1">
          <FieldLabel>{label}</FieldLabel>
          {description ? <FieldDescription>{description}</FieldDescription> : null}
        </div>
        <Checkbox checked={Boolean(value)} onCheckedChange={checked => onChange(checked === true)} />
      </Field>
    )
  }

  if (field.type === 'select') {
    const options = (field.options ?? []).map(option =>
      typeof option === 'string' ? { label: option, value: option } : option
    )

    return (
      <Field>
        <FieldLabel>{label}</FieldLabel>
        <Select value={typeof value === 'string' ? value : ''} onValueChange={next => onChange(next ?? '')}>
          <SelectTrigger className="w-full">
            <SelectValue />
          </SelectTrigger>
          <SelectContent>
            {options.map(option => (
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

  if (field.type === 'string_array') {
    return (
      <Field>
        <FieldLabel>{label}</FieldLabel>
        <Textarea
          value={Array.isArray(value) ? value.join('\n') : ''}
          onChange={event =>
            // Accept both newline and comma input because setup fields often copy
            // from provider consoles or docs with different list formats.
            onChange(
              event.target.value
                .split(/\n|,/)
                .map(item => item.trim())
                .filter(Boolean)
            )
          }
        />
        {description ? <FieldDescription>{description}</FieldDescription> : null}
      </Field>
    )
  }

  return (
    <Field>
      <FieldLabel>{label}</FieldLabel>
      <Input
        max={field.max}
        min={field.min}
        type={field.type === 'secret' ? 'password' : field.type === 'integer' ? 'number' : 'text'}
        value={value == null ? '' : String(value)}
        onChange={event => onChange(field.type === 'integer' ? Number(event.target.value) : event.target.value)}
      />
      {description ? <FieldDescription>{description}</FieldDescription> : null}
    </Field>
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
function ErrorAlert({ error }: { error?: unknown }) {
  const { t } = useTranslation()
  if (!error) return null

  return (
    <Alert variant="destructive">
      <AlertTitle>{t('common.error')}</AlertTitle>
      <AlertDescription>
        <pre className="whitespace-pre-wrap text-xs">{apiErrorMessage(error)}</pre>
      </AlertDescription>
    </Alert>
  )
}

/** Shows the first validation error from Formisch field state. */
function FormFieldError({ errors }: { errors: [string, ...string[]] | null }) {
  return errors ? <UiFieldError>{errors[0]}</UiFieldError> : null
}

/** Resolves plugin-provided localized text with simple language fallback. */
function localizedText(value: LocalizedText, locale: string): string | undefined {
  if (!value) return undefined
  if (typeof value === 'string') return value

  const language = locale.split('-')[0]
  return value[locale] ?? value[language] ?? value['en-US'] ?? Object.values(value)[0]
}

/** Builds the initial config object from plugin-declared field defaults. */
function defaultConfig(fields: SetupField[]): JsonObject {
  return fields.reduce<JsonObject>((config, field) => setPath(config, field.path, defaultValue(field)), {})
}

/** Chooses a JSON-safe fallback value for a setup field without an explicit default. */
function defaultValue(field: SetupField): JsonValue {
  if (field.default !== undefined) return field.default
  if (field.type === 'boolean') return false
  if (field.type === 'integer') return 0
  if (field.type === 'string_array') return []
  if (field.type === 'select') {
    const first = field.options?.[0]
    return typeof first === 'string' ? first : (first?.value ?? '')
  }
  return ''
}

/** Reads a dot-path from a JSON object used by plugin setup fields. */
function getPath(source: JsonObject, path: string): JsonValue | undefined {
  return path.split('.').reduce<JsonValue | undefined>((value, segment) => {
    if (value && typeof value === 'object' && !Array.isArray(value)) return value[segment]
    return undefined
  }, source)
}

/** Writes a dot-path without mutating the previous setup config object. */
function setPath(source: JsonObject, path: string, value: JsonValue): JsonObject {
  const segments = path.split('.')
  const [head, ...rest] = segments

  if (!head) return source
  if (rest.length === 0) return { ...source, [head]: value }

  const current = source[head]
  // Only plain object children can be traversed. Arrays and scalars are replaced
  // so a stale field shape cannot corrupt a nested adapter config.
  const child = current && typeof current === 'object' && !Array.isArray(current) ? (current as JsonObject) : {}

  return {
    ...source,
    [head]: setPath(child, rest.join('.'), value)
  }
}

/** Returns unique non-empty values while preserving user-visible order. */
function unique(values: string[]): string[] {
  return [...new Set(values.filter(Boolean))]
}
