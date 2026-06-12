import { RiSaveLine } from '@remixicon/react'
import { useMutation, useQuery, useQueryClient } from '@tanstack/react-query'
import { useEffect, useMemo, useState } from 'react'
import { useTranslation } from 'react-i18next'
import { api, unwrap } from '@/lib/api'
import type { ConsoleSecretProjection, ConsoleWebTools } from '@/console/service'
import { Badge } from '@/uikit/components/badge'
import { Button } from '@/uikit/components/button'
import { Card, CardContent, CardHeader, CardTitle } from '@/uikit/components/card'
import { Checkbox } from '@/uikit/components/checkbox'
import { CreatableCombobox, type CreatableComboboxOption } from '@/uikit/components/creatable-combobox'
import { Field, FieldDescription, FieldGroup, FieldLabel } from '@/uikit/components/field'
import { Input } from '@/uikit/components/input'
import { Spinner } from '@/uikit/components/spinner'
import { Table, TableBody, TableCell, TableHead, TableHeader, TableRow } from '@/uikit/components/table'
import { ErrorAlert, SectionHeader, SkeletonRows } from '../shared'

type WebToolFormState = {
  searchProvider: string
  extractProvider: string
  exaApiKey: string
  parallelApiKey: string
  jinaApiKey: string
  clearExaApiKey: boolean
  clearParallelApiKey: boolean
  clearJinaApiKey: boolean
}

export function WebToolsPage() {
  const { t } = useTranslation()
  const queryClient = useQueryClient()
  const webTools = useQuery({
    queryKey: ['console-web-tools'],
    queryFn: () => unwrap(api.console['web-tools'].get())
  })
  const data = webTools.data?.webTools
  const [form, setForm] = useState<WebToolFormState>(() => webToolFormFromData(undefined))
  const searchProviderOptions = useMemo(() => providerOptions(data, 'search', t), [data, t])
  const extractProviderOptions = useMemo(() => providerOptions(data, 'extract', t), [data, t])

  useEffect(() => {
    if (data) setForm(webToolFormFromData(data))
  }, [data])

  const save = useMutation({
    mutationFn: () =>
      unwrap(
        api.console['web-tools'].put({
          searchProvider: providerValueForSave(form.searchProvider),
          extractProvider: providerValueForSave(form.extractProvider),
          exaApiKey: secretValueForSave(form.exaApiKey, form.clearExaApiKey),
          parallelApiKey: secretValueForSave(form.parallelApiKey, form.clearParallelApiKey),
          jinaApiKey: secretValueForSave(form.jinaApiKey, form.clearJinaApiKey)
        })
      ),
    onSuccess: () => queryClient.invalidateQueries({ queryKey: ['console-web-tools'] })
  })

  function patch(patchValue: Partial<WebToolFormState>) {
    setForm(current => ({ ...current, ...patchValue }))
  }

  return (
    <div className="flex w-full max-w-7xl flex-col gap-6">
      <SectionHeader title={t('console.web_tools.title')} description={t('console.web_tools.description')} />
      {webTools.isPending ? (
        <SkeletonRows rows={4} />
      ) : webTools.error ? (
        <ErrorAlert error={webTools.error} title={t('console.web_tools.load_failed')} />
      ) : data ? (
        <>
          <Card size="sm">
            <CardHeader>
              <CardTitle className="text-base">{t('console.web_tools.routing_title')}</CardTitle>
            </CardHeader>
            <CardContent>
              <form
                className="grid gap-5"
                onSubmit={event => {
                  event.preventDefault()
                  save.mutate()
                }}>
                <FieldGroup className="grid gap-4 md:grid-cols-2">
                  <Field>
                    <FieldLabel>{t('console.web_tools.search_provider_label')}</FieldLabel>
                    <CreatableCombobox
                      value={form.searchProvider}
                      options={searchProviderOptions}
                      placeholder={t('console.web_tools.default_fallback')}
                      emptyLabel={t('console.web_tools.no_matching_provider')}
                      createLabel={value => t('console.web_tools.use_provider_id', { value })}
                      onValueChange={value => patch({ searchProvider: value })}
                    />
                    <FieldDescription>
                      <code>ai_agent.web.search_provider</code> - {t('console.web_tools.search_provider_description')}
                    </FieldDescription>
                  </Field>
                  <Field>
                    <FieldLabel>{t('console.web_tools.extract_provider_label')}</FieldLabel>
                    <CreatableCombobox
                      value={form.extractProvider}
                      options={extractProviderOptions}
                      placeholder={t('console.web_tools.default_fallback')}
                      emptyLabel={t('console.web_tools.no_matching_provider')}
                      createLabel={value => t('console.web_tools.use_provider_id', { value })}
                      onValueChange={value => patch({ extractProvider: value })}
                    />
                    <FieldDescription>
                      <code>ai_agent.web.extract_provider</code> - {t('console.web_tools.extract_provider_description')}
                    </FieldDescription>
                  </Field>
                </FieldGroup>

                <section className="grid gap-4 border border-border/70 bg-card/40 p-4">
                  <div className="grid gap-1">
                    <p className="text-xs font-semibold uppercase text-muted-foreground">
                      {t('console.web_tools.api_keys_title')}
                    </p>
                    <p className="text-sm text-muted-foreground">{t('console.web_tools.api_keys_description')}</p>
                  </div>
                  <FieldGroup className="grid gap-4 md:grid-cols-3">
                    <SecretField
                      label={t('console.web_tools.exa_api_key_label')}
                      configKey="ai_agent.web.exa.api_key"
                      secret={data.apiKeys.exa}
                      value={form.exaApiKey}
                      clear={form.clearExaApiKey}
                      onValueChange={value => patch({ exaApiKey: value })}
                      onClearChange={clearExaApiKey => patch({ clearExaApiKey })}
                    />
                    <SecretField
                      label={t('console.web_tools.parallel_api_key_label')}
                      configKey="ai_agent.web.parallel.api_key"
                      secret={data.apiKeys.parallel}
                      value={form.parallelApiKey}
                      clear={form.clearParallelApiKey}
                      onValueChange={value => patch({ parallelApiKey: value })}
                      onClearChange={clearParallelApiKey => patch({ clearParallelApiKey })}
                    />
                    <SecretField
                      label={t('console.web_tools.jina_api_key_label')}
                      configKey="ai_agent.web.jina.api_key"
                      secret={data.apiKeys.jina}
                      value={form.jinaApiKey}
                      clear={form.clearJinaApiKey}
                      onValueChange={value => patch({ jinaApiKey: value })}
                      onClearChange={clearJinaApiKey => patch({ clearJinaApiKey })}
                      description={t('console.web_tools.jina_key_optional')}
                    />
                  </FieldGroup>
                </section>

                <div className="flex flex-wrap items-center gap-2">
                  <Button type="submit" disabled={save.isPending}>
                    {save.isPending ? <Spinner /> : <RiSaveLine />}
                    {t('console.web_tools.save_button')}
                  </Button>
                  {save.isSuccess && !save.isPending ? (
                    <span className="text-sm text-muted-foreground">{t('console.web_tools.saved_note')}</span>
                  ) : null}
                </div>
              </form>
              <ErrorAlert error={save.error} title={t('console.web_tools.save_failed')} />
            </CardContent>
          </Card>

          <Card size="sm">
            <CardHeader>
              <CardTitle className="text-base">{t('console.web_tools.providers_title')}</CardTitle>
            </CardHeader>
            <CardContent>
              <div className="border border-border bg-card">
                <Table>
                  <TableHeader>
                    <TableRow>
                      <TableHead>{t('console.web_tools.column_provider')}</TableHead>
                      <TableHead>{t('console.web_tools.column_supports')}</TableHead>
                      <TableHead>{t('console.web_tools.column_search')}</TableHead>
                      <TableHead>{t('console.web_tools.column_extract')}</TableHead>
                    </TableRow>
                  </TableHeader>
                  <TableBody>
                    {data.providers.map(provider => (
                      <TableRow key={provider.id}>
                        <TableCell className="font-mono text-xs">
                          <div className="flex flex-wrap items-center gap-2">
                            <span>{provider.id}</span>
                            {provider.builtIn ? (
                              <Badge variant="outline">{t('console.web_tools.built_in')}</Badge>
                            ) : null}
                          </div>
                        </TableCell>
                        <TableCell>
                          <div className="flex flex-wrap gap-1">
                            {provider.supports.map(kind => (
                              <Badge key={kind} variant="secondary">
                                {kind}
                              </Badge>
                            ))}
                          </div>
                        </TableCell>
                        <TableCell>
                          <ProviderAvailability availability={provider.availability.search} />
                        </TableCell>
                        <TableCell>
                          <ProviderAvailability availability={provider.availability.extract} />
                        </TableCell>
                      </TableRow>
                    ))}
                  </TableBody>
                </Table>
              </div>
            </CardContent>
          </Card>
        </>
      ) : null}
    </div>
  )
}

function SecretField({
  label,
  configKey,
  secret,
  value,
  clear,
  description,
  onValueChange,
  onClearChange
}: {
  label: string
  configKey: string
  secret: ConsoleSecretProjection
  value: string
  clear: boolean
  description?: string
  onValueChange(value: string): void
  onClearChange(value: boolean): void
}) {
  const { t } = useTranslation()
  return (
    <Field>
      <FieldLabel>{label}</FieldLabel>
      <Input
        type="password"
        disabled={clear}
        placeholder={secret.present ? t('console.web_tools.api_key_keep_placeholder') : ''}
        value={value}
        onChange={event => onValueChange(event.target.value)}
      />
      <FieldDescription>
        <code>{configKey}</code>
        {secret.present ? ` - ${t('console.web_tools.secret_saved')}` : ''}
        {description ? ` - ${description}` : ''}
      </FieldDescription>
      <label className="flex items-center gap-2 text-sm text-muted-foreground">
        <Checkbox
          checked={clear}
          disabled={!secret.present}
          onCheckedChange={checked => onClearChange(Boolean(checked))}
        />
        {t('console.web_tools.clear_saved_key')}
      </label>
    </Field>
  )
}

function ProviderAvailability({
  availability
}: {
  availability?: {
    available: boolean
    reason: string | null
  }
}) {
  const { t } = useTranslation()
  if (!availability) return <span className="text-muted-foreground">-</span>
  return (
    <div className="flex min-w-0 flex-col gap-1">
      <Badge variant={availability.available ? 'default' : 'secondary'}>
        {availability.available ? t('console.web_tools.available') : t('console.web_tools.unavailable')}
      </Badge>
      {!availability.available && availability.reason ? (
        <span className="max-w-72 truncate text-xs text-muted-foreground">{availability.reason}</span>
      ) : null}
    </div>
  )
}

function webToolFormFromData(data: ConsoleWebTools | undefined): WebToolFormState {
  return {
    searchProvider: data?.searchProvider ?? '',
    extractProvider: data?.extractProvider ?? '',
    exaApiKey: '',
    parallelApiKey: '',
    jinaApiKey: '',
    clearExaApiKey: false,
    clearParallelApiKey: false,
    clearJinaApiKey: false
  }
}

function providerOptions(
  data: ConsoleWebTools | undefined,
  kind: 'search' | 'extract',
  t: (key: string) => string
): CreatableComboboxOption[] {
  return (data?.providers ?? [])
    .filter(provider => provider.supports.includes(kind))
    .map(provider => ({
      value: provider.id,
      label: provider.id,
      description: provider.availability[kind]?.available
        ? t('console.web_tools.available')
        : provider.availability[kind]?.reason || undefined
    }))
}

function providerValueForSave(value: string): string | null {
  const trimmed = value.trim()
  return trimmed ? trimmed : null
}

function secretValueForSave(value: string, clear: boolean): string | null | undefined {
  if (clear) return null
  const trimmed = value.trim()
  return trimmed ? trimmed : undefined
}
