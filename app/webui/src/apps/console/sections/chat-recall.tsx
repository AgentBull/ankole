import { RiSaveLine, RiSearchLine, RiSparkling2Line, RiTimerLine } from '@remixicon/react'
import { useMutation, useQuery, useQueryClient } from '@tanstack/react-query'
import { useEffect, useState } from 'react'
import { useTranslation } from 'react-i18next'
import { api, unwrap } from '@/lib/api'
import type { ConsoleChatRecall } from '@/console/service'
import type { ChatRecallConfig } from '@/chat-recall/config'
import { Alert, AlertDescription, AlertTitle } from '@/uikit/components/alert'
import { Badge } from '@/uikit/components/badge'
import { Button } from '@/uikit/components/button'
import { Card, CardContent, CardHeader, CardTitle } from '@/uikit/components/card'
import { Field, FieldGroup, FieldLabel } from '@/uikit/components/field'
import { Input } from '@/uikit/components/input'
import { Select, SelectContent, SelectItem, SelectTrigger, SelectValue } from '@/uikit/components/select'
import { Spinner } from '@/uikit/components/spinner'
import { Switch } from '@/uikit/components/switch'
import { Table, TableBody, TableCell, TableHead, TableHeader, TableRow } from '@/uikit/components/table'
import { numberInputValue, optionalFiniteNumber, optionalPositiveInteger } from '../helpers'
import { ErrorAlert, MetricCard, SectionHeader, SkeletonRows } from '../shared'

type ChatRecallProviderKind = NonNullable<NonNullable<ChatRecallConfig['vector']>['providerKind']>
type ChatRecallIndexStrategy = NonNullable<NonNullable<ChatRecallConfig['vector']>['indexStrategy']>

type ChatRecallFormState = {
  vectorEnabled: boolean
  providerKind: '' | ChatRecallProviderKind
  providerId: string
  model: string
  dimensions: string
  batchSize: string
  concurrency: string
  indexStrategy: ChatRecallIndexStrategy
  rerankLimit: string
  rrfK: string
  recencyHalfLifeDays: string
  mmrLambda: string
  workerEnabled: boolean
  pollIntervalMs: string
  maxAttempts: string
}

const CHAT_RECALL_PROVIDER_KINDS = ['openai', 'openrouter', 'vllm'] as const satisfies readonly ChatRecallProviderKind[]
const CHAT_RECALL_INDEX_STRATEGIES = [
  'auto',
  'halfvec_hnsw',
  'binary_quantized_hnsw',
  'exact_only'
] as const satisfies readonly ChatRecallIndexStrategy[]

export function ChatRecallPage() {
  const { t } = useTranslation()
  const queryClient = useQueryClient()
  const chatRecall = useQuery({
    queryKey: ['console-chat-recall'],
    queryFn: () => unwrap(api.console['chat-recall'].get())
  })
  const providers = useQuery({
    queryKey: ['console-llm-providers'],
    queryFn: () => unwrap(api.console['llm-providers'].get())
  })
  const data = chatRecall.data?.chatRecall
  const [form, setForm] = useState<ChatRecallFormState>(() => chatRecallFormFromConfig(undefined))
  const ready = data?.status.enabled === true
  const savingBlocked =
    form.vectorEnabled && (!form.providerKind || !form.providerId.trim() || !form.model.trim() || providers.isPending)

  useEffect(() => {
    if (data?.config) setForm(chatRecallFormFromConfig(data.config))
  }, [data?.config])

  const save = useMutation({
    mutationFn: () => unwrap(api.console['chat-recall'].put(chatRecallConfigFromForm(form))),
    onSuccess: () => queryClient.invalidateQueries({ queryKey: ['console-chat-recall'] })
  })
  const testEmbedding = useMutation({
    mutationFn: () => unwrap(api.console['chat-recall']['embedding-test'].post())
  })
  const reindex = useMutation({
    mutationFn: () => unwrap(api.console['chat-recall'].reindex.post()),
    onSuccess: () => queryClient.invalidateQueries({ queryKey: ['console-chat-recall'] })
  })
  const pause = useMutation({
    mutationFn: () => unwrap(api.console['chat-recall'].pause.post()),
    onSuccess: () => queryClient.invalidateQueries({ queryKey: ['console-chat-recall'] })
  })
  const resume = useMutation({
    mutationFn: () => unwrap(api.console['chat-recall'].resume.post()),
    onSuccess: () => queryClient.invalidateQueries({ queryKey: ['console-chat-recall'] })
  })

  function patch(patchValue: Partial<ChatRecallFormState>) {
    setForm(current => ({ ...current, ...patchValue }))
  }

  return (
    <div className="flex w-full max-w-7xl flex-col gap-6">
      <SectionHeader title={t('console.chat_recall.title')} description={t('console.chat_recall.description')} />
      {chatRecall.isPending ? (
        <SkeletonRows rows={4} />
      ) : chatRecall.error ? (
        <ErrorAlert error={chatRecall.error} title={t('console.chat_recall.load_failed')} />
      ) : data ? (
        <>
          {!ready ? (
            <Alert>
              <AlertTitle>{t('console.chat_recall.unavailable_title')}</AlertTitle>
              <AlertDescription>
                {data.status.disabledReasons.join('; ') || t('console.chat_recall.disabled_fallback')}
              </AlertDescription>
            </Alert>
          ) : null}

          <section className="grid gap-4 md:grid-cols-2 xl:grid-cols-4">
            <MetricCard label={t('console.chat_recall.metric_documents')} value={data.status.stats.documents} />
            <MetricCard
              label={t('console.chat_recall.metric_embedding_backlog')}
              value={data.status.stats.embeddingBacklog}
            />
            <MetricCard
              label={t('console.chat_recall.metric_embedding_synced')}
              value={data.status.stats.embeddingSynced}
            />
            <Card size="sm">
              <CardContent className="flex flex-col gap-2">
                <span className="text-xs font-medium tracking-wider text-muted-foreground uppercase">
                  {t('console.chat_recall.runtime_label')}
                </span>
                <div className="flex flex-wrap gap-2">
                  <StatusBadge
                    active={ready}
                    label={ready ? t('console.chat_recall.status_ready') : t('console.chat_recall.status_disabled')}
                  />
                  <Badge variant="outline">{data.status.worker.state}</Badge>
                </div>
              </CardContent>
            </Card>
          </section>

          <Card size="sm">
            <CardHeader>
              <CardTitle className="text-base">{t('console.chat_recall.readiness_title')}</CardTitle>
            </CardHeader>
            <CardContent>
              <div className="border border-border bg-card">
                <Table>
                  <TableHeader>
                    <TableRow>
                      <TableHead>{t('console.chat_recall.column_extension')}</TableHead>
                      <TableHead>{t('console.chat_recall.column_available')}</TableHead>
                      <TableHead>{t('console.chat_recall.column_installed')}</TableHead>
                      <TableHead>{t('console.chat_recall.column_version')}</TableHead>
                      <TableHead>{t('console.chat_recall.column_error')}</TableHead>
                    </TableRow>
                  </TableHeader>
                  <TableBody>
                    {Object.values(data.status.extensions).map(extension => (
                      <TableRow key={extension.name}>
                        <TableCell className="font-mono text-xs">{extension.name}</TableCell>
                        <TableCell>
                          <StatusBadge
                            active={extension.available}
                            label={extension.available ? t('console.yes') : t('console.no')}
                          />
                        </TableCell>
                        <TableCell>
                          <StatusBadge
                            active={extension.installed}
                            label={extension.installed ? t('console.yes') : t('console.no')}
                          />
                        </TableCell>
                        <TableCell>{extension.version ?? '-'}</TableCell>
                        <TableCell className="max-w-[320px] truncate">{extension.error ?? '-'}</TableCell>
                      </TableRow>
                    ))}
                  </TableBody>
                </Table>
              </div>
              {data.status.schemaError ? (
                <p className="mt-3 text-sm text-destructive">{data.status.schemaError}</p>
              ) : null}
              {data.status.worker.lastError ? (
                <p className="mt-3 text-sm text-destructive">{data.status.worker.lastError}</p>
              ) : null}
            </CardContent>
          </Card>

          <Card size="sm">
            <CardHeader>
              <CardTitle className="text-base">{t('console.chat_recall.configuration_title')}</CardTitle>
            </CardHeader>
            <CardContent>
              <form
                className="grid gap-5"
                onSubmit={event => {
                  event.preventDefault()
                  save.mutate()
                }}>
                <section className="grid gap-4 border border-border/70 bg-card/40 p-4">
                  <div className="flex flex-wrap items-center justify-between gap-3">
                    <div className="grid gap-1">
                      <p className="text-xs font-semibold uppercase text-muted-foreground">
                        {t('console.chat_recall.vector_section')}
                      </p>
                      <p className="text-sm text-muted-foreground">{t('console.chat_recall.vector_description')}</p>
                    </div>
                    <Switch
                      checked={form.vectorEnabled}
                      onCheckedChange={checked => patch({ vectorEnabled: checked })}
                    />
                  </div>
                  <FieldGroup className="grid gap-4 md:grid-cols-2 xl:grid-cols-4">
                    <Field>
                      <FieldLabel>{t('console.chat_recall.provider_kind_label')}</FieldLabel>
                      <Select
                        value={form.providerKind || 'openai'}
                        onValueChange={value => patch({ providerKind: value as ChatRecallProviderKind })}>
                        <SelectTrigger className="w-full">
                          <SelectValue />
                        </SelectTrigger>
                        <SelectContent>
                          {CHAT_RECALL_PROVIDER_KINDS.map(kind => (
                            <SelectItem key={kind} value={kind}>
                              {kind}
                            </SelectItem>
                          ))}
                        </SelectContent>
                      </Select>
                    </Field>
                    <Field>
                      <FieldLabel>{t('console.chat_recall.provider_id_label')}</FieldLabel>
                      <Select value={form.providerId} onValueChange={value => patch({ providerId: value ?? '' })}>
                        <SelectTrigger className="w-full">
                          <SelectValue placeholder={t('console.select_provider')} />
                        </SelectTrigger>
                        <SelectContent>
                          {(providers.data?.providers ?? []).map(provider => (
                            <SelectItem key={provider.providerId} value={provider.providerId}>
                              {provider.providerId}
                            </SelectItem>
                          ))}
                        </SelectContent>
                      </Select>
                    </Field>
                    <Field>
                      <FieldLabel>{t('console.chat_recall.embedding_model_label')}</FieldLabel>
                      <Input value={form.model} onChange={event => patch({ model: event.target.value })} />
                    </Field>
                    <Field>
                      <FieldLabel>{t('console.chat_recall.dimensions_label')}</FieldLabel>
                      <Input
                        type="number"
                        min={1}
                        step={1}
                        placeholder="4096"
                        value={form.dimensions}
                        onChange={event => patch({ dimensions: event.target.value })}
                      />
                    </Field>
                    <Field>
                      <FieldLabel>{t('console.chat_recall.index_strategy_label')}</FieldLabel>
                      <Select
                        value={form.indexStrategy}
                        onValueChange={value => patch({ indexStrategy: value as ChatRecallIndexStrategy })}>
                        <SelectTrigger className="w-full">
                          <SelectValue />
                        </SelectTrigger>
                        <SelectContent>
                          {CHAT_RECALL_INDEX_STRATEGIES.map(strategy => (
                            <SelectItem key={strategy} value={strategy}>
                              {strategy}
                            </SelectItem>
                          ))}
                        </SelectContent>
                      </Select>
                    </Field>
                    <Field>
                      <FieldLabel>{t('console.chat_recall.batch_size_label')}</FieldLabel>
                      <Input value={form.batchSize} onChange={event => patch({ batchSize: event.target.value })} />
                    </Field>
                    <Field>
                      <FieldLabel>{t('console.chat_recall.concurrency_label')}</FieldLabel>
                      <Input value={form.concurrency} onChange={event => patch({ concurrency: event.target.value })} />
                    </Field>
                  </FieldGroup>
                </section>

                <section className="grid gap-4 border border-border/70 bg-card/40 p-4">
                  <p className="text-xs font-semibold uppercase text-muted-foreground">
                    {t('console.chat_recall.rerank_section')}
                  </p>
                  <FieldGroup className="grid gap-4 md:grid-cols-2 xl:grid-cols-4">
                    <Field>
                      <FieldLabel>{t('console.chat_recall.rerank_limit_label')}</FieldLabel>
                      <Input value={form.rerankLimit} onChange={event => patch({ rerankLimit: event.target.value })} />
                    </Field>
                    <Field>
                      <FieldLabel>{t('console.chat_recall.rrf_k_label')}</FieldLabel>
                      <Input value={form.rrfK} onChange={event => patch({ rrfK: event.target.value })} />
                    </Field>
                    <Field>
                      <FieldLabel>{t('console.chat_recall.recency_half_life_label')}</FieldLabel>
                      <Input
                        value={form.recencyHalfLifeDays}
                        onChange={event => patch({ recencyHalfLifeDays: event.target.value })}
                      />
                    </Field>
                    <Field>
                      <FieldLabel>{t('console.chat_recall.mmr_lambda_label')}</FieldLabel>
                      <Input value={form.mmrLambda} onChange={event => patch({ mmrLambda: event.target.value })} />
                    </Field>
                    <Field>
                      <FieldLabel>{t('console.chat_recall.worker_label')}</FieldLabel>
                      <div className="flex h-9 items-center">
                        <Switch
                          checked={form.workerEnabled}
                          onCheckedChange={checked => patch({ workerEnabled: checked })}
                        />
                      </div>
                    </Field>
                    <Field>
                      <FieldLabel>{t('console.chat_recall.poll_interval_label')}</FieldLabel>
                      <Input
                        value={form.pollIntervalMs}
                        onChange={event => patch({ pollIntervalMs: event.target.value })}
                      />
                    </Field>
                    <Field>
                      <FieldLabel>{t('console.chat_recall.max_attempts_label')}</FieldLabel>
                      <Input value={form.maxAttempts} onChange={event => patch({ maxAttempts: event.target.value })} />
                    </Field>
                  </FieldGroup>
                </section>

                <div className="flex flex-wrap items-center gap-2">
                  <Button type="submit" disabled={save.isPending || savingBlocked}>
                    {save.isPending ? <Spinner /> : <RiSaveLine />}
                    {t('console.chat_recall.save_button')}
                  </Button>
                  <Button
                    type="button"
                    variant="outline"
                    disabled={!ready || testEmbedding.isPending}
                    onClick={() => testEmbedding.mutate()}>
                    {testEmbedding.isPending ? <Spinner /> : <RiSparkling2Line />}
                    {t('console.chat_recall.test_embedding_button')}
                  </Button>
                  <Button
                    type="button"
                    variant="outline"
                    disabled={!ready || reindex.isPending}
                    onClick={() => reindex.mutate()}>
                    {reindex.isPending ? <Spinner /> : <RiSearchLine />}
                    {t('console.chat_recall.reindex_button')}
                  </Button>
                  <Button
                    type="button"
                    variant="outline"
                    disabled={!ready || pause.isPending}
                    onClick={() => pause.mutate()}>
                    {pause.isPending ? <Spinner /> : <RiTimerLine />}
                    {t('console.chat_recall.pause_button')}
                  </Button>
                  <Button
                    type="button"
                    variant="outline"
                    disabled={!ready || resume.isPending}
                    onClick={() => resume.mutate()}>
                    {resume.isPending ? <Spinner /> : <RiTimerLine />}
                    {t('console.chat_recall.resume_button')}
                  </Button>
                  {testEmbedding.data ? (
                    <span className="text-sm text-muted-foreground">
                      {t('console.chat_recall.embedding_dimensions_result', {
                        dimensions: testEmbedding.data.dimensions
                      })}
                    </span>
                  ) : null}
                </div>
                <ErrorAlert
                  error={save.error ?? testEmbedding.error ?? reindex.error ?? pause.error ?? resume.error}
                  title={t('console.chat_recall.operation_failed')}
                />
              </form>
            </CardContent>
          </Card>
        </>
      ) : null}
    </div>
  )
}

function chatRecallFormFromConfig(config: ConsoleChatRecall['config'] | undefined): ChatRecallFormState {
  return {
    vectorEnabled: config?.vector.enabled ?? false,
    providerKind: config?.vector.providerKind ?? '',
    providerId: config?.vector.providerId ?? '',
    model: config?.vector.model ?? '',
    dimensions: numberInputValue(config?.vector.dimensions),
    batchSize: numberInputValue(config?.vector.batchSize ?? 32),
    concurrency: numberInputValue(config?.vector.concurrency ?? 1),
    indexStrategy: config?.vector.indexStrategy ?? 'auto',
    rerankLimit: numberInputValue(config?.rerank.limit ?? 10),
    rrfK: numberInputValue(config?.rerank.rrfK ?? 60),
    recencyHalfLifeDays: numberInputValue(config?.rerank.recencyHalfLifeDays ?? 30),
    mmrLambda: numberInputValue(config?.rerank.mmrLambda ?? 0.78),
    workerEnabled: config?.worker.enabled ?? true,
    pollIntervalMs: numberInputValue(config?.worker.pollIntervalMs ?? 10_000),
    maxAttempts: numberInputValue(config?.worker.maxAttempts ?? 5)
  }
}

function chatRecallConfigFromForm(form: ChatRecallFormState): ChatRecallConfig {
  return {
    vector: {
      enabled: form.vectorEnabled,
      providerKind: form.providerKind || undefined,
      providerId: form.providerId.trim() || undefined,
      model: form.model.trim() || undefined,
      dimensions: optionalPositiveInteger(form.dimensions, 'embedding dimensions'),
      batchSize: optionalPositiveInteger(form.batchSize, 'embedding batch size') ?? 32,
      concurrency: optionalPositiveInteger(form.concurrency, 'embedding concurrency') ?? 1,
      indexStrategy: form.indexStrategy
    },
    rerank: {
      limit: optionalPositiveInteger(form.rerankLimit, 'rerank limit') ?? 10,
      rrfK: optionalFiniteNumber(form.rrfK, 'RRF K') ?? 60,
      recencyHalfLifeDays: optionalFiniteNumber(form.recencyHalfLifeDays, 'recency half-life') ?? 30,
      mmrLambda: optionalFiniteNumber(form.mmrLambda, 'MMR lambda') ?? 0.78
    },
    worker: {
      enabled: form.workerEnabled,
      pollIntervalMs: optionalPositiveInteger(form.pollIntervalMs, 'worker poll interval') ?? 10_000,
      maxAttempts: optionalPositiveInteger(form.maxAttempts, 'worker max attempts') ?? 5
    }
  }
}

function StatusBadge({ active, label }: { active: boolean; label: string }) {
  return <Badge variant={active ? 'default' : 'secondary'}>{label}</Badge>
}
