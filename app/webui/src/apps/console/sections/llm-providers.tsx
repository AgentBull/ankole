import { RiAddLine, RiDeleteBinLine, RiPencilLine, RiSaveLine, RiSparkling2Line } from '@remixicon/react'
import type { BullXPluginJsonValue } from '@agentbull/bullx-sdk/plugins'
import { useMutation, useQuery, useQueryClient } from '@tanstack/react-query'
import { useEffect, useState } from 'react'
import { useTranslation } from 'react-i18next'
import { api, unwrap } from '@/lib/api'
import type { AiAgentModelProfileConfig } from '@/ai-agent/config'
import { isPluginConfigJsonObject as isJsonObject, type PluginConfigJsonObject } from '@/plugins/config-json'
import { Alert, AlertDescription, AlertTitle } from '@/uikit/components/alert'
import { Button } from '@/uikit/components/button'
import { Card, CardContent, CardHeader, CardTitle } from '@/uikit/components/card'
import { Field, FieldDescription, FieldGroup, FieldLabel } from '@/uikit/components/field'
import { Input } from '@/uikit/components/input'
import { Select, SelectContent, SelectItem, SelectTrigger, SelectValue } from '@/uikit/components/select'
import { Spinner } from '@/uikit/components/spinner'
import { TableCell, TableRow } from '@/uikit/components/table'
import { numberInputValue, optionalPositiveInteger, TRANSPORT_OPTIONS } from '../helpers'
import { ErrorAlert, SectionHeader, TableCard } from '../shared'

type JsonValue = BullXPluginJsonValue
type JsonObject = PluginConfigJsonObject

export function LlmProvidersPage() {
  const { t } = useTranslation()
  const queryClient = useQueryClient()
  const providers = useQuery({
    queryKey: ['console-llm-providers'],
    queryFn: () => unwrap(api.console['llm-providers'].get())
  })
  const [editingProviderId, setEditingProviderId] = useState<string | null>(null)
  const [providerId, setProviderId] = useState('')
  const [piProvider, setPiProvider] = useState('')
  const [baseUrl, setBaseUrl] = useState('')
  const [apiKey, setApiKey] = useState('')
  const [checkModel, setCheckModel] = useState('')
  const [providerOptions, setProviderOptions] = useState<LlmProviderOptionsFormState>(() =>
    llmProviderOptionsFormFromValue({})
  )
  const editingProvider = providers.data?.providers.find(provider => provider.providerId === editingProviderId)
  const create = useMutation({
    mutationFn: () =>
      unwrap(
        api.console['llm-providers'].post({
          providerId,
          piProvider,
          baseUrl: baseUrl.trim() ? baseUrl : null,
          apiKey: apiKey.trim() ? apiKey : null,
          providerOptions: llmProviderOptionsFromForm(providerOptions)
        })
      ),
    onSuccess: () => {
      setEditingProviderId(null)
      setProviderId('')
      setPiProvider('')
      setBaseUrl('')
      setApiKey('')
      setCheckModel('')
      setProviderOptions(llmProviderOptionsFormFromValue({}))
      queryClient.invalidateQueries({ queryKey: ['console-llm-providers'] })
    }
  })
  const update = useMutation({
    mutationFn: () =>
      unwrap(
        api.console['llm-providers']({ providerId }).put({
          piProvider,
          baseUrl: baseUrl.trim() ? baseUrl : null,
          apiKey: apiKey.trim() ? apiKey : undefined,
          providerOptions: llmProviderOptionsFromForm(providerOptions)
        })
      ),
    onSuccess: () => {
      setApiKey('')
      queryClient.invalidateQueries({ queryKey: ['console-llm-providers'] })
    }
  })
  const check = useMutation({
    mutationFn: () =>
      unwrap(
        api.console['llm-providers'].check.post({
          providerId: providerId || undefined,
          piProvider: piProvider || undefined,
          model: checkModel.trim() || undefined,
          baseUrl: baseUrl.trim() ? baseUrl : null,
          apiKey: apiKey.trim() ? apiKey : undefined,
          providerOptions: llmProviderOptionsFromForm(providerOptions)
        })
      )
  })
  const remove = useMutation({
    mutationFn: (id: string) => unwrap(api.console['llm-providers']({ providerId: id }).delete()),
    onSuccess: () => queryClient.invalidateQueries({ queryKey: ['console-llm-providers'] })
  })

  useEffect(() => {
    if (!editingProvider) return
    setProviderId(editingProvider.providerId)
    setPiProvider(editingProvider.piProvider)
    setBaseUrl(editingProvider.baseUrl ?? '')
    setApiKey('')
    setCheckModel('')
    setProviderOptions(llmProviderOptionsFormFromValue(editingProvider.providerOptions ?? {}))
  }, [editingProvider])

  function resetForm() {
    setEditingProviderId(null)
    setProviderId('')
    setPiProvider('')
    setBaseUrl('')
    setApiKey('')
    setCheckModel('')
    setProviderOptions(llmProviderOptionsFormFromValue({}))
  }

  function changePiProvider(nextPiProvider: string | null) {
    const value = nextPiProvider ?? ''
    if (!editingProviderId && (!providerId.trim() || providerId === piProvider)) {
      setProviderId(value)
    }
    setPiProvider(value)
  }

  return (
    <div className="flex w-full max-w-7xl flex-col gap-6">
      <SectionHeader title={t('console.llm_providers.title')} description={t('console.llm_providers.description')} />
      <Card size="sm">
        <CardHeader>
          <CardTitle className="text-base">
            {editingProviderId ? t('console.llm_providers.edit_provider') : t('console.llm_providers.create_provider')}
          </CardTitle>
        </CardHeader>
        <CardContent>
          <form
            className="grid gap-4"
            onSubmit={event => {
              event.preventDefault()
              editingProviderId ? update.mutate() : create.mutate()
            }}>
            <section className="grid gap-4 border border-border/70 bg-card/40 p-4">
              <p className="text-xs font-semibold uppercase text-muted-foreground">
                {t('console.llm_providers.provider_section')}
              </p>
              <FieldGroup className="grid gap-4 md:grid-cols-2 xl:grid-cols-4">
                <Field>
                  <FieldLabel>{t('console.llm_providers.pi_provider_label')}</FieldLabel>
                  <Select value={piProvider} onValueChange={changePiProvider}>
                    <SelectTrigger className="w-full">
                      <SelectValue placeholder={t('console.llm_providers.select_pi_provider')} />
                    </SelectTrigger>
                    <SelectContent>
                      {(providers.data?.piProviders ?? []).map(provider => (
                        <SelectItem key={provider.id} value={provider.id}>
                          {provider.id} ({provider.modelCount})
                        </SelectItem>
                      ))}
                    </SelectContent>
                  </Select>
                </Field>
                <Field>
                  <FieldLabel>{t('console.llm_providers.provider_id_label')}</FieldLabel>
                  <Input
                    value={providerId}
                    disabled={Boolean(editingProviderId)}
                    onChange={event => setProviderId(event.target.value)}
                  />
                  <FieldDescription>{t('console.llm_providers.provider_id_description')}</FieldDescription>
                </Field>
                <Field>
                  <FieldLabel>{t('console.llm_providers.base_url_label')}</FieldLabel>
                  <Input value={baseUrl} onChange={event => setBaseUrl(event.target.value)} />
                </Field>
                <Field>
                  <FieldLabel>{t('console.llm_providers.api_key_label')}</FieldLabel>
                  <Input
                    type="password"
                    placeholder={
                      editingProvider?.apiKey.present ? t('console.llm_providers.api_key_keep_placeholder') : ''
                    }
                    value={apiKey}
                    onChange={event => setApiKey(event.target.value)}
                  />
                  {editingProvider?.apiKey.present ? (
                    <FieldDescription>{t('console.llm_providers.api_key_keep_description')}</FieldDescription>
                  ) : null}
                </Field>
              </FieldGroup>
            </section>

            <LlmProviderOptionsForm value={providerOptions} onChange={setProviderOptions} />

            <section className="grid gap-4 border border-border/70 bg-card/40 p-4">
              <div className="grid gap-1">
                <p className="text-xs font-semibold uppercase text-muted-foreground">
                  {t('console.llm_providers.check_section')}
                </p>
                <p className="text-sm text-muted-foreground">{t('console.llm_providers.check_description')}</p>
              </div>
              <FieldGroup className="grid gap-4 md:grid-cols-[minmax(0,1fr)_auto] md:items-end">
                <Field>
                  <FieldLabel>{t('console.llm_providers.check_model_label')}</FieldLabel>
                  <Input value={checkModel} onChange={event => setCheckModel(event.target.value)} />
                </Field>
                <Button
                  type="button"
                  variant="outline"
                  disabled={!piProvider || check.isPending}
                  onClick={() => check.mutate()}>
                  {check.isPending ? <Spinner /> : <RiSparkling2Line />}
                  {t('console.llm_providers.check_button')}
                </Button>
              </FieldGroup>
            </section>
            <div className="flex flex-wrap items-center gap-2">
              <Button
                type="submit"
                disabled={!providerId.trim() || !piProvider || create.isPending || update.isPending}>
                {create.isPending || update.isPending ? (
                  <Spinner />
                ) : editingProviderId ? (
                  <RiSaveLine />
                ) : (
                  <RiAddLine />
                )}
                {editingProviderId
                  ? t('console.llm_providers.save_provider')
                  : t('console.llm_providers.create_provider')}
              </Button>
              <Button type="button" variant="ghost" onClick={resetForm}>
                {t('console.clear')}
              </Button>
            </div>
          </form>
          {check.data ? (
            <Alert>
              <AlertTitle>{t('console.llm_providers.check_passed')}</AlertTitle>
              <AlertDescription>
                {check.data.provider.providerId}
                {check.data.model ? ` / ${check.data.model.id}` : ''}
              </AlertDescription>
            </Alert>
          ) : null}
          <ErrorAlert
            error={create.error ?? update.error ?? check.error}
            title={t('console.llm_providers.operation_failed')}
          />
        </CardContent>
      </Card>
      <TableCard
        loading={providers.isPending}
        error={providers.error}
        empty={providers.data?.providers.length === 0}
        columns={[
          t('console.llm_providers.column_provider'),
          t('console.llm_providers.column_pi_provider'),
          t('console.llm_providers.base_url_label'),
          t('console.llm_providers.api_key_label'),
          t('console.actions')
        ]}>
        {(providers.data?.providers ?? []).map(provider => (
          <TableRow key={provider.providerId}>
            <TableCell className="font-mono text-xs">{provider.providerId}</TableCell>
            <TableCell>{provider.piProvider}</TableCell>
            <TableCell className="max-w-[280px] truncate">{provider.baseUrl ?? '-'}</TableCell>
            <TableCell>{provider.apiKey.present ? provider.apiKey.masked : '-'}</TableCell>
            <TableCell>
              <div className="flex justify-end gap-1">
                <Button variant="ghost" size="icon-xs" onClick={() => setEditingProviderId(provider.providerId)}>
                  <RiPencilLine />
                </Button>
                <Button
                  variant="ghost"
                  size="icon-xs"
                  disabled={remove.isPending}
                  onClick={() => {
                    if (
                      window.confirm(t('console.llm_providers.delete_confirm', { providerId: provider.providerId }))
                    ) {
                      remove.mutate(provider.providerId)
                    }
                  }}>
                  <RiDeleteBinLine />
                </Button>
              </div>
            </TableCell>
          </TableRow>
        ))}
      </TableCard>
    </div>
  )
}

type KeyValueDraftRow = {
  key: string
  value: string
}

type LlmProviderOptionsFormState = {
  compat: KeyValueDraftRow[]
  headers: KeyValueDraftRow[]
  maxRetries: string
  maxRetryDelayMs: string
  timeoutMs: string
  transport: '' | NonNullable<AiAgentModelProfileConfig['transport']>
  websocketConnectTimeoutMs: string
}

function LlmProviderOptionsForm({
  value,
  onChange
}: {
  value: LlmProviderOptionsFormState
  onChange(value: LlmProviderOptionsFormState): void
}) {
  const { t } = useTranslation()
  function patch(patchValue: Partial<LlmProviderOptionsFormState>) {
    onChange({ ...value, ...patchValue })
  }

  return (
    <section className="grid gap-4 border border-border/70 bg-card/40 p-4">
      <div className="grid gap-1">
        <p className="text-xs font-semibold uppercase text-muted-foreground">
          {t('console.llm_providers.runtime_options_title')}
        </p>
        <p className="text-sm text-muted-foreground">{t('console.llm_providers.runtime_options_description')}</p>
      </div>
      <FieldGroup className="grid gap-4 md:grid-cols-2 xl:grid-cols-3">
        <Field>
          <FieldLabel>{t('console.llm_providers.request_timeout_label')}</FieldLabel>
          <Input
            type="number"
            min={1}
            step={1}
            value={value.timeoutMs}
            onChange={event => patch({ timeoutMs: event.target.value })}
          />
          <FieldDescription>{t('console.llm_providers.milliseconds_hint')}</FieldDescription>
        </Field>
        <Field>
          <FieldLabel>{t('console.llm_providers.websocket_timeout_label')}</FieldLabel>
          <Input
            type="number"
            min={1}
            step={1}
            value={value.websocketConnectTimeoutMs}
            onChange={event => patch({ websocketConnectTimeoutMs: event.target.value })}
          />
          <FieldDescription>{t('console.llm_providers.milliseconds_hint')}</FieldDescription>
        </Field>
        <Field>
          <FieldLabel>{t('console.llm_providers.max_retries_label')}</FieldLabel>
          <Input
            type="number"
            min={0}
            step={1}
            value={value.maxRetries}
            onChange={event => patch({ maxRetries: event.target.value })}
          />
        </Field>
        <Field>
          <FieldLabel>{t('console.llm_providers.max_retry_delay_label')}</FieldLabel>
          <Input
            type="number"
            min={0}
            step={1}
            value={value.maxRetryDelayMs}
            onChange={event => patch({ maxRetryDelayMs: event.target.value })}
          />
          <FieldDescription>{t('console.llm_providers.milliseconds_hint')}</FieldDescription>
        </Field>
        <Field>
          <FieldLabel>{t('console.llm_providers.transport_label')}</FieldLabel>
          <Select
            value={value.transport || 'default'}
            onValueChange={transport =>
              patch({
                transport:
                  transport === 'default' ? '' : (transport as NonNullable<AiAgentModelProfileConfig['transport']>)
              })
            }>
            <SelectTrigger className="w-full">
              <SelectValue />
            </SelectTrigger>
            <SelectContent>
              <SelectItem value="default">{t('console.default_option')}</SelectItem>
              {TRANSPORT_OPTIONS.map(option => (
                <SelectItem key={option} value={option}>
                  {option}
                </SelectItem>
              ))}
            </SelectContent>
          </Select>
        </Field>
      </FieldGroup>
      <LlmProviderKeyValueRows
        title={t('console.llm_providers.http_headers_title')}
        description={t('console.llm_providers.http_headers_description')}
        rows={value.headers}
        keyPlaceholder="x-provider-option"
        valuePlaceholder="value"
        onChange={headers => patch({ headers })}
      />
      <LlmProviderKeyValueRows
        title={t('console.llm_providers.compat_title')}
        description={t('console.llm_providers.compat_description')}
        rows={value.compat}
        keyPlaceholder="supportsDeveloperRole"
        valuePlaceholder="true"
        onChange={compat => patch({ compat })}
      />
    </section>
  )
}

function LlmProviderKeyValueRows({
  title,
  description,
  rows,
  keyPlaceholder,
  valuePlaceholder,
  onChange
}: {
  title: string
  description: string
  rows: KeyValueDraftRow[]
  keyPlaceholder: string
  valuePlaceholder: string
  onChange(rows: KeyValueDraftRow[]): void
}) {
  const { t } = useTranslation()
  function patchRow(index: number, patch: Partial<KeyValueDraftRow>) {
    onChange(rows.map((row, rowIndex) => (rowIndex === index ? { ...row, ...patch } : row)))
  }

  return (
    <Field>
      <div className="grid gap-1">
        <FieldLabel>{title}</FieldLabel>
        <FieldDescription>{description}</FieldDescription>
      </div>
      <div className="grid gap-2">
        {rows.map((row, index) => (
          <div key={index} className="grid gap-2 md:grid-cols-[minmax(0,1fr)_minmax(0,1fr)_auto]">
            <Input
              value={row.key}
              placeholder={keyPlaceholder}
              onChange={event => patchRow(index, { key: event.target.value })}
            />
            <Input
              value={row.value}
              placeholder={valuePlaceholder}
              onChange={event => patchRow(index, { value: event.target.value })}
            />
            <Button
              type="button"
              variant="ghost"
              size="icon-sm"
              aria-label={t('console.llm_providers.remove_row_aria', { title, row: index + 1 })}
              onClick={() => onChange(rows.filter((_row, rowIndex) => rowIndex !== index))}>
              <RiDeleteBinLine />
            </Button>
          </div>
        ))}
        <Button
          type="button"
          variant="outline"
          size="sm"
          className="w-fit"
          onClick={() => onChange([...rows, { key: '', value: '' }])}>
          <RiAddLine />
          {t('console.llm_providers.add_row')}
        </Button>
      </div>
    </Field>
  )
}

function llmProviderOptionsFormFromValue(value: JsonObject): LlmProviderOptionsFormState {
  const headers = isJsonObject(value.headers) ? value.headers : {}
  const compat = isJsonObject(value.compat) ? value.compat : {}

  return {
    compat: keyValueRowsFromJsonObject(compat),
    headers: keyValueRowsFromJsonObject(headers, { forceString: true }),
    maxRetries: numberInputValue(typeof value.maxRetries === 'number' ? value.maxRetries : undefined),
    maxRetryDelayMs: numberInputValue(typeof value.maxRetryDelayMs === 'number' ? value.maxRetryDelayMs : undefined),
    timeoutMs: numberInputValue(typeof value.timeoutMs === 'number' ? value.timeoutMs : undefined),
    transport: isLlmTransport(value.transport) ? value.transport : '',
    websocketConnectTimeoutMs: numberInputValue(
      typeof value.websocketConnectTimeoutMs === 'number' ? value.websocketConnectTimeoutMs : undefined
    )
  }
}

function llmProviderOptionsFromForm(form: LlmProviderOptionsFormState): JsonObject {
  const options: JsonObject = {}
  const headers = jsonObjectFromKeyValueRows(form.headers, { forceString: true })
  const compat = jsonObjectFromKeyValueRows(form.compat)
  const timeoutMs = optionalPositiveInteger(form.timeoutMs, 'Request timeout')
  const websocketConnectTimeoutMs = optionalPositiveInteger(form.websocketConnectTimeoutMs, 'WebSocket connect timeout')
  const maxRetries = optionalNonNegativeInteger(form.maxRetries, 'Max retries')
  const maxRetryDelayMs = optionalNonNegativeInteger(form.maxRetryDelayMs, 'Max retry delay')

  if (Object.keys(headers).length > 0) options.headers = headers
  if (timeoutMs !== undefined) options.timeoutMs = timeoutMs
  if (websocketConnectTimeoutMs !== undefined) options.websocketConnectTimeoutMs = websocketConnectTimeoutMs
  if (maxRetries !== undefined) options.maxRetries = maxRetries
  if (maxRetryDelayMs !== undefined) options.maxRetryDelayMs = maxRetryDelayMs
  if (form.transport) options.transport = form.transport
  if (Object.keys(compat).length > 0) options.compat = compat

  return options
}

function keyValueRowsFromJsonObject(value: JsonObject, options: { forceString?: boolean } = {}): KeyValueDraftRow[] {
  return Object.entries(value).map(([key, item]) => ({
    key,
    value: options.forceString && typeof item === 'string' ? item : jsonInputValue(item)
  }))
}

function jsonObjectFromKeyValueRows(rows: KeyValueDraftRow[], options: { forceString?: boolean } = {}): JsonObject {
  const result: JsonObject = {}
  for (const row of rows) {
    const key = row.key.trim()
    const rawValue = row.value.trim()
    if (!key || !rawValue) continue
    result[key] = options.forceString ? rawValue : parseLooseJsonValue(rawValue)
  }
  return result
}

function parseLooseJsonValue(value: string): JsonValue {
  try {
    return JSON.parse(value) as JsonValue
  } catch {
    return value
  }
}

function jsonInputValue(value: JsonValue): string {
  if (typeof value === 'string') return value
  return JSON.stringify(value)
}

function isLlmTransport(value: JsonValue | undefined): value is NonNullable<AiAgentModelProfileConfig['transport']> {
  return (
    typeof value === 'string' &&
    TRANSPORT_OPTIONS.includes(value as NonNullable<AiAgentModelProfileConfig['transport']>)
  )
}

function optionalNonNegativeInteger(value: string, label: string): number | undefined {
  const trimmed = value.trim()
  if (!trimmed) return undefined

  const parsed = Number(trimmed)
  if (!Number.isInteger(parsed) || parsed < 0) throw new Error(`${label} must be a non-negative integer`)
  return parsed
}
