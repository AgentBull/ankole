import { TableRow, useQuery, useSearchParams } from '../tenant-context'
import { ACTIVITY_REFRESH_MS } from '../refresh-intervals'
import { Sheet, SheetContent, SheetDescription, SheetHeader, SheetTitle, Skeleton, TableCell } from '@ankole/uikit'
import { CodeRegular } from '@ankole/uikit/icons'

import { useState } from 'react'
import { useTranslation } from 'react-i18next'

import { fromDocument } from '../api/json-api'
import {
  getAutomationJobOptions,
  listAutomationJobRunsOptions,
  listAutomationJobsOptions
} from '../api/v2/generated/@tanstack/react-query.gen'
import { StatusIndicator, type StatusTone } from '../console-form'
import { ErrorBlock } from '../../common/error-block'
import { requestErrorCode } from '../../common/request-errors'
import { formatConsoleDate, formatJSON, resourceID } from '../console-primitives'
import { FilterSwitch, ResourceListPage, ResourceSearch, RowViewAction } from '../console-list-page'
import { matchesResourceSearch } from '../state/resource-search'

export type AutomationJobItem = {
  id: string
  page_id: string
  action_key: string
  authorization_kind: string
  human_uid: string | null
  config: Record<string, unknown>
  label: string
  status: 'active' | 'cancelled'
  source_provenance: Record<string, unknown>
  inserted_at: string
  updated_at: string
}

type AutomationJobRunItem = {
  id: string
  status: 'queued' | 'running' | 'succeeded' | 'failed' | 'cancelled'
  attempts: number
  started_at: string | null
  finished_at: string | null
  slice_count: number
  progress: Record<string, unknown>
  result: unknown
  error: string | null
}

/** The list of automation jobs, also read by the route loader. */
export function automationJobListOptions() {
  return listAutomationJobsOptions({ query: { page: { limit: 100 } } })
}

export function AutomationJobsPage() {
  const { t } = useTranslation()
  const [searchParams, setSearchParams] = useSearchParams()
  const [query, setQuery] = useState('')
  const [includeFinished, setIncludeFinished] = useState(false)
  const selectedID = resourceID(searchParams.get('job'), 1)

  const jobs = useQuery({
    ...automationJobListOptions(),
    select: document => fromDocument(document) as AutomationJobItem[],
    refetchInterval: ACTIVITY_REFRESH_MS
  })
  const allJobs = jobs.data ?? []
  const detailPath = { id: String(selectedID ?? 1000) }
  const detailEnabled = selectedID !== undefined

  const detail = useQuery({
    ...getAutomationJobOptions({ path: detailPath }),
    select: document => fromDocument(document) as AutomationJobItem,
    enabled: detailEnabled,
    refetchInterval: selectedID !== undefined ? ACTIVITY_REFRESH_MS : false,
    retry: false
  })
  const runs = useQuery({
    ...listAutomationJobRunsOptions({
      path: { automation_job_id: selectedID ?? 1000 },
      query: { page: { limit: 20 } }
    }),
    select: document => fromDocument(document) as AutomationJobRunItem[],
    enabled: detailEnabled,
    refetchInterval: selectedID !== undefined ? ACTIVITY_REFRESH_MS : false,
    retry: false
  })
  const detailNotFound = requestErrorCode(detail.error) === 'not_found'

  const rows = allJobs
    .filter(job => includeFinished || job.status === 'active')
    .filter(job =>
      matchesResourceSearch(query, job.label, job.status, job.page_id, job.action_key, job.human_uid, String(job.id))
    )

  const openJob = (job: Pick<AutomationJobItem, 'id'>) =>
    setSearchParams(current => automationJobDetailParams(current, job))

  const closeJob = () => {
    const next = new URLSearchParams(searchParams)
    next.delete('job')
    setSearchParams(next, { replace: true })
  }

  return (
    <>
      <ResourceListPage
        title={t('console.automation_jobs.title')}
        description={t('console.automation_jobs.description')}
        columns={[
          t('console.automation_jobs.label'),
          t('console.automation_jobs.page'),
          t('console.automation_jobs.action'),
          t('console.automation_jobs.authority'),
          t('console.automation_jobs.status'),
          t('console.automation_jobs.created_at')
        ]}
        count={rows.length}
        emptyTitle={t('console.automation_jobs.empty_title')}
        emptyIcon={<CodeRegular aria-hidden />}
        emptyDescription={t('console.automation_jobs.empty_description')}
        error={jobs.error}
        isEmpty={rows.length === 0}
        isFiltered={Boolean(query.trim())}
        onClearFilters={() => {
          setQuery('')
        }}
        isLoading={jobs.isLoading}
        toolbarCanRevealRows
        toolbar={
          <ResourceSearch
            label={t('console.automation_jobs.search_placeholder')}
            value={query}
            onChange={setQuery}
            filters={
              <>
                <FilterSwitch
                  checked={includeFinished}
                  label={t('console.include_finished')}
                  onChange={setIncludeFinished}
                />
              </>
            }
          />
        }>
        {rows.map(job => (
          <AutomationJobRow key={job.id} job={job} onOpen={() => openJob(job)} />
        ))}
      </ResourceListPage>

      <Sheet open={selectedID !== undefined} onOpenChange={open => !open && closeJob()}>
        <SheetContent
          closeLabel={t('common.close')}
          className="data-[side=right]:w-full data-[side=right]:sm:max-w-[min(64rem,92vw)]">
          <SheetHeader className="gap-3 border-b border-border pb-6">
            <SheetTitle>{detail.data?.label ?? t('console.automation_jobs.detail_title')}</SheetTitle>
            <SheetDescription>
              {detail.data ? (
                <span className="font-mono text-xs">
                  #{detail.data.id} · {detail.data.action_key}
                </span>
              ) : null}
            </SheetDescription>
          </SheetHeader>
          <div className="min-w-0 flex-1 overflow-y-auto p-6">
            {detailNotFound ? (
              <ErrorBlock error={t('console.automation_jobs.not_found', { id: selectedID })} />
            ) : detail.error || runs.error ? (
              <ErrorBlock error={detail.error ?? runs.error} />
            ) : detail.isLoading || runs.isLoading || !detail.data ? (
              <Skeleton className="h-64 w-full" />
            ) : (
              <AutomationJobDetail job={detail.data} runs={runs.data ?? []} />
            )}
          </div>
        </SheetContent>
      </Sheet>
    </>
  )
}

export function automationJobDetailParams(
  current: URLSearchParams,
  job: Pick<AutomationJobItem, 'id'>
): URLSearchParams {
  const next = new URLSearchParams(current)
  next.delete('agent')
  next.set('job', String(job.id))
  return next
}

function AutomationJobRow({ job, onOpen }: { job: AutomationJobItem; onOpen: () => void }) {
  const { t } = useTranslation()

  return (
    <TableRow>
      <TableCell>
        <button type="button" data-row-link className="grid gap-1 text-left" onClick={onOpen}>
          <span className="font-medium text-foreground">{job.label}</span>
          <span className="font-mono text-xs text-muted-foreground">#{job.id}</span>
        </button>
      </TableCell>
      <TableCell>
        <span className="block max-w-56 truncate font-mono text-xs" title={job.page_id}>
          {job.page_id}
        </span>
      </TableCell>
      <TableCell>
        <span className="font-mono text-xs">{job.action_key}</span>
      </TableCell>
      <TableCell>{job.human_uid ?? t('console.automation_jobs.service')}</TableCell>
      <TableCell>
        <StatusIndicator tone={jobStatusTone(job.status)}>
          {t(`console.automation_jobs.status_${job.status}`)}
        </StatusIndicator>
      </TableCell>
      <TableCell>{formatConsoleDate(job.inserted_at)}</TableCell>
      <RowViewAction label={t('common.view_details_for', { name: job.label })} onOpen={onOpen} />
    </TableRow>
  )
}

function AutomationJobDetail({ job, runs }: { job: AutomationJobItem; runs: AutomationJobRunItem[] }) {
  const { t } = useTranslation()

  return (
    <div className="grid min-w-0 gap-8">
      <section className="grid gap-3 border border-border bg-card p-4">
        <div className="flex flex-wrap items-center gap-3">
          <StatusIndicator tone={jobStatusTone(job.status)}>
            {t(`console.automation_jobs.status_${job.status}`)}
          </StatusIndicator>
          <span className="text-sm text-muted-foreground">{t('console.automation_jobs.attempt_policy')}</span>
        </div>
        <dl className="grid gap-3 text-sm md:grid-cols-2">
          <Fact label={t('console.automation_jobs.page')} value={job.page_id} mono />
          <Fact label={t('console.automation_jobs.action')} value={job.action_key} mono />
          <Fact
            label={t('console.automation_jobs.authority')}
            value={job.human_uid ?? t('console.automation_jobs.service')}
          />
          <Fact label={t('console.automation_jobs.created_at')} value={formatConsoleDate(job.inserted_at)} />
          <Fact label={t('console.automation_jobs.updated_at')} value={formatConsoleDate(job.updated_at)} />
        </dl>
        <details>
          <summary className="cursor-pointer text-sm font-medium">{t('console.automation_jobs.config')}</summary>
          <pre className="mt-2 max-h-56 overflow-auto border border-border bg-muted p-3 text-xs">
            {formatJSON(job.config)}
          </pre>
        </details>
      </section>

      <section className="grid gap-3">
        <h3 className="font-medium">{t('console.automation_jobs.run_history')}</h3>
        {runs.length === 0 ? (
          <p className="text-sm text-muted-foreground">{t('console.automation_jobs.no_runs')}</p>
        ) : (
          runs.map(run => <AutomationJobRun key={run.id} run={run} />)
        )}
      </section>
    </div>
  )
}

function AutomationJobRun({ run }: { run: AutomationJobRunItem }) {
  const { t } = useTranslation()

  return (
    <article className="grid min-w-0 gap-3 border border-border bg-card p-4">
      <header className="flex flex-wrap items-center justify-between gap-3">
        <div className="flex items-center gap-3">
          <span className="font-mono text-xs">#{run.id}</span>
          <StatusIndicator tone={runStatusTone(run.status)}>
            {t(`console.automation_jobs.run_status_${run.status}`)}
          </StatusIndicator>
        </div>
        <span className="text-xs text-muted-foreground">
          {t('console.automation_jobs.attempts', { count: run.attempts })}
        </span>
      </header>
      <div className="flex flex-wrap gap-x-4 gap-y-1 text-xs text-muted-foreground">
        <span>{formatConsoleDate(run.started_at)}</span>
        <span>→</span>
        <span>{formatConsoleDate(run.finished_at)}</span>
      </div>
      {run.error ? <p className="break-words text-sm text-destructive-foreground">{firstLine(run.error)}</p> : null}
      {Object.keys(run.progress).length ? (
        <RunLog label={t('console.automation_jobs.progress')} value={formatJSON(run.progress)} />
      ) : null}
      {run.result != null ? (
        <RunLog label={t('console.automation_jobs.result')} value={formatJSON(run.result)} />
      ) : null}
    </article>
  )
}

function firstLine(text: string): string {
  return text.split('\n', 1)[0] ?? ''
}

function RunLog({ label, value }: { label: string; value: string }) {
  return (
    <details>
      <summary className="cursor-pointer font-mono text-xs">{label}</summary>
      <pre className="mt-2 max-h-64 overflow-auto whitespace-pre-wrap border border-border bg-muted p-3 text-xs">
        {value}
      </pre>
    </details>
  )
}

function Fact({ label, value, mono = false }: { label: string; value: string; mono?: boolean }) {
  return (
    <div className="grid min-w-0 gap-1">
      <dt className="text-xs text-muted-foreground">{label}</dt>
      <dd className={mono ? 'break-all font-mono text-xs' : ''}>{value}</dd>
    </div>
  )
}

function jobStatusTone(status: AutomationJobItem['status']): StatusTone {
  switch (status) {
    case 'active':
      return 'positive'
    case 'cancelled':
      return 'neutral'
  }
}

function runStatusTone(status: AutomationJobRunItem['status']): StatusTone {
  switch (status) {
    case 'queued':
      return 'neutral'
    case 'running':
      return 'info'
    case 'succeeded':
      return 'positive'
    case 'failed':
      return 'danger'
    case 'cancelled':
      return 'neutral'
  }
}
