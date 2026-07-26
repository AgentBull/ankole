import { Badge, Card, CardContent, CardDescription, CardHeader, CardTitle, Skeleton } from '@ankole/uikit'
import { useQuery } from '@tanstack/react-query'
import { useEffect } from 'react'
import { useTranslation } from 'react-i18next'
import { useSearchParams } from 'react-router'
import {
  ankoleWebBrainControllerStatusOptions,
  ankoleWebPrincipalControllerIndexOptions
} from '../api/generated/@tanstack/react-query.gen'
import type { JsonValue as JSONValue } from '../api/generated/types.gen'
import { ErrorBlock, formatJSON } from '../console-primitives'
import { StatusIndicator } from '../console-form'
import { PageHeader, RefreshButton } from '../console-list-page'
import { defaultBrainOwnerUID, setBrainFilter } from '../state/brain-editor-model'
import { BrainOwnerField, BrainTaskNavigation } from './brain-shared'

export function BrainStatusPage() {
  const { t } = useTranslation()
  const [searchParams, setSearchParams] = useSearchParams()
  const principals = useQuery(ankoleWebPrincipalControllerIndexOptions())
  const ownerUID = searchParams.get('owner') ?? defaultBrainOwnerUID(principals.data?.principals ?? [])
  const query = useQuery({
    ...ankoleWebBrainControllerStatusOptions({ query: { owner_uid: ownerUID } }),
    enabled: Boolean(ownerUID)
  })

  useEffect(() => {
    if (searchParams.has('owner') || !ownerUID) return
    const next = new URLSearchParams(searchParams)
    next.set('owner', ownerUID)
    setSearchParams(next, { replace: true })
  }, [ownerUID, searchParams, setSearchParams])

  const status = jsonObject(query.data?.memory_status)
  const alerts = jsonArray(status?.alerts)
  const stageA = jsonObject(status?.stage_a)
  const stageB = jsonObject(status?.stage_b)
  const embedding = jsonObject(status?.embedding)
  const lints = jsonObject(status?.lints)
  const memo = jsonArray(status?.memo)
  const stuckJobs = jsonArray(status?.stuck_curation_jobs)

  return (
    <div className="grid min-w-0 gap-5">
      <PageHeader
        title={t('console.brain.status_title')}
        description={t('console.brain.status_description')}
        actions={<RefreshButton />}
      />
      <BrainTaskNavigation active="status" ownerUID={ownerUID} />
      <div className="grid grid-cols-1 gap-4 border border-border bg-card p-4 md:grid-cols-2">
        <BrainOwnerField
          ownerUID={ownerUID}
          principals={principals.data?.principals ?? []}
          onChange={value => setSearchParams(setBrainFilter(searchParams, 'owner', value), { replace: true })}
        />
        <div className="flex items-center justify-between gap-3 self-end border border-border p-3">
          <span className="text-sm text-muted-foreground">{t('console.brain.status_overall')}</span>
          <StatusIndicator tone={status?.status === 'ok' ? 'positive' : 'warning'}>
            {textValue(status?.status) ?? '—'}
          </StatusIndicator>
        </div>
      </div>

      <ErrorBlock error={query.error ?? principals.error} />
      {query.isLoading || principals.isLoading ? (
        <div className="grid grid-cols-1 gap-4 lg:grid-cols-2">
          <Skeleton className="h-48" />
          <Skeleton className="h-48" />
        </div>
      ) : status ? (
        <>
          <Card>
            <CardHeader>
              <CardTitle>{t('console.brain.status_alerts')}</CardTitle>
              <CardDescription>
                {t('console.brain.status_generated_at', { value: textValue(status.generated_at) })}
              </CardDescription>
            </CardHeader>
            <CardContent className="flex flex-wrap gap-2">
              {alerts.length === 0 ? (
                <Badge variant="secondary">{t('console.brain.status_no_alerts')}</Badge>
              ) : (
                alerts.map(alert => (
                  <Badge key={String(alert)} variant="warning">
                    {String(alert)}
                  </Badge>
                ))
              )}
            </CardContent>
          </Card>

          <div className="grid grid-cols-1 items-start gap-4 lg:grid-cols-2">
            <PipelineCard title={t('console.brain.status_episode_embeddings')} value={jsonObject(stageA?.episodes)} />
            <PipelineCard
              title={t('console.brain.status_block_embeddings')}
              value={jsonObject(status.entry_block_embeddings)}
            />
            <ObjectCard title={t('console.brain.status_embedding_config')} value={embedding} />
            <ObjectCard title={t('console.brain.status_stage_b')} value={stageB} />
          </div>

          <Card>
            <CardHeader>
              <CardTitle>{t('console.brain.status_stage_a_channels')}</CardTitle>
              <CardDescription>{t('console.brain.status_stage_a_channels_description')}</CardDescription>
            </CardHeader>
            <CardContent className="grid gap-2">
              {jsonArray(stageA?.channels).map((channel, index) => (
                <StatusRow key={candidateKey(channel, index)} value={channel} />
              ))}
            </CardContent>
          </Card>

          <div className="grid grid-cols-1 items-start gap-4 lg:grid-cols-2">
            <CollectionCard title={t('console.brain.status_memo')} values={memo} />
            <CollectionCard title={t('console.brain.status_stuck_jobs')} values={stuckJobs} />
          </div>

          <Card>
            <CardHeader>
              <CardTitle>{t('console.brain.status_lints')}</CardTitle>
              <CardDescription>{t('console.brain.status_lints_description')}</CardDescription>
            </CardHeader>
            <CardContent className="grid grid-cols-1 gap-3 sm:grid-cols-2">
              {Object.entries(lints ?? {}).map(([name, value]) => {
                const lint = jsonObject(value)
                const count = numberValue(lint?.count)
                return (
                  <div key={name} className="flex items-center justify-between border border-border p-3">
                    <span className="text-sm font-medium">{name}</span>
                    <Badge variant={count > 0 ? 'warning' : 'secondary'}>{count}</Badge>
                  </div>
                )
              })}
            </CardContent>
          </Card>

          <ObjectCard title={t('console.brain.status_diagnostics')} value={jsonObject(status.diagnostics)} />
        </>
      ) : null}
    </div>
  )
}

function PipelineCard({ title, value }: { title: string; value?: Record<string, JSONValue> }) {
  return (
    <Card>
      <CardHeader>
        <CardTitle>{title}</CardTitle>
      </CardHeader>
      <CardContent className="grid grid-cols-2 gap-3 text-sm sm:grid-cols-4">
        {['total', 'pending', 'synced', 'failed'].map(key => (
          <div key={key} className="border border-border p-3">
            <div className="text-xs text-muted-foreground">{key}</div>
            <div className="mt-1 text-lg font-semibold">{numberValue(value?.[key])}</div>
          </div>
        ))}
      </CardContent>
    </Card>
  )
}

function ObjectCard({ title, value }: { title: string; value?: Record<string, JSONValue> }) {
  return (
    <Card>
      <CardHeader>
        <CardTitle>{title}</CardTitle>
      </CardHeader>
      <CardContent>
        <pre className="max-h-80 overflow-auto whitespace-pre-wrap break-all text-xs text-muted-foreground">
          {formatJSON(value ?? {})}
        </pre>
      </CardContent>
    </Card>
  )
}

function CollectionCard({ title, values }: { title: string; values: JSONValue[] }) {
  return (
    <Card>
      <CardHeader>
        <div className="flex items-center justify-between gap-3">
          <CardTitle>{title}</CardTitle>
          <Badge variant={values.length > 0 ? 'warning' : 'secondary'}>{values.length}</Badge>
        </div>
      </CardHeader>
      <CardContent className="grid gap-2">
        {values.length === 0 ? <span className="text-sm text-muted-foreground">—</span> : null}
        {values.map((value, index) => (
          <StatusRow key={candidateKey(value, index)} value={value} />
        ))}
      </CardContent>
    </Card>
  )
}

function StatusRow({ value }: { value: JSONValue }) {
  return (
    <pre className="overflow-auto whitespace-pre-wrap break-all border border-border p-3 text-xs text-muted-foreground">
      {formatJSON(value)}
    </pre>
  )
}

function jsonObject(value: JSONValue | undefined): Record<string, JSONValue> | undefined {
  return value && typeof value === 'object' && !Array.isArray(value) ? (value as Record<string, JSONValue>) : undefined
}

function jsonArray(value: JSONValue | undefined): JSONValue[] {
  return Array.isArray(value) ? value : []
}

function textValue(value: JSONValue | undefined): string | undefined {
  return typeof value === 'string' && value ? value : undefined
}

function numberValue(value: JSONValue | undefined): number {
  return typeof value === 'number' ? value : 0
}

function candidateKey(value: JSONValue, index: number): string {
  const object = jsonObject(value)
  return textValue(object?.channel_id) || textValue(object?.entry_id) || String(object?.job_id ?? index)
}
