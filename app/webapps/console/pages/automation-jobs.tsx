import { ACTIVITY_REFRESH_MS } from '../refresh-intervals'
import {
  Sheet,
  SheetContent,
  SheetDescription,
  SheetHeader,
  SheetTitle,
  Skeleton,
  TableCell,
  TableRow
} from '@ankole/uikit'
import { RiCodeSSlashLine } from '@remixicon/react'
import { useQuery } from '@tanstack/react-query'
import { useState } from 'react'
import { useTranslation } from 'react-i18next'
import { useSearchParams } from 'react-router'
import {
  ankoleWebAutomationJobControllerIndexOptions,
  ankoleWebAutomationJobControllerShowOptions
} from '../api/generated/@tanstack/react-query.gen'
import type { AutomationJobItem, AutomationJobRunItem } from '../api/generated/types.gen'
import { AgentFilter, useAgentScope } from '../console-agent-scope'
import { StatusIndicator } from '../console-form'
import { ErrorBlock } from '../../common/error-block'
import { formatConsoleDate, formatJSON, resourceID } from '../console-primitives'
import { AgentCell, FilterSwitch, ResourceListPage, ResourceSearch, RowViewAction } from '../console-list-page'
import { matchesResourceSearch } from '../state/resource-search'

export function AutomationJobsPage() {
  const { t } = useTranslation()
  const [searchParams, setSearchParams] = useSearchParams()
  const [query, setQuery] = useState('')
  const [includeFinished, setIncludeFinished] = useState(false)
  const scope = useAgentScope()
  const selectedID = resourceID(searchParams.get('job'), 1)

  const jobs = useQuery({
    ...ankoleWebAutomationJobControllerIndexOptions({
      query: { agent: scope.agentUID || undefined, limit: 100 }
    }),
    refetchInterval: ACTIVITY_REFRESH_MS
  })
  const allJobs = jobs.data?.automation_jobs ?? []
  const selectedAgentUID = automationJobAgentUID(allJobs, selectedID, scope.agentUID)

  const detail = useQuery({
    ...ankoleWebAutomationJobControllerShowOptions({
      path: { agent_uid: selectedAgentUID, automation_job_id: selectedID ?? 1000 },
      query: { runs: 20 }
    }),
    enabled: Boolean(selectedAgentUID) && selectedID !== undefined,
    refetchInterval: selectedID !== undefined ? ACTIVITY_REFRESH_MS : false,
    retry: false
  })
  const detailNotFound = detail.error?.error?.code === 'not_found'

  const rows = allJobs
    .filter(job => includeFinished || job.status === 'active')
    .filter(job =>
      matchesResourceSearch(
        query,
        job.label,
        job.status,
        job.agent_uid,
        job.directory_path,
        job.owner_session_id,
        String(job.id)
      )
    )

  const openJob = (job: Pick<AutomationJobItem, 'id' | 'agent_uid'>) =>
    setSearchParams(current => automationJobDetailParams(current, job))

  const closeJob = () => {
    const next = new URLSearchParams(searchParams)
    next.delete('job')
    setSearchParams(next, { replace: true })
  }

  const selectAgent = (agentUID: string) => setSearchParams(current => automationJobScopeParams(current, agentUID))

  return (
    <>
      <ResourceListPage
        title={t('console.automation_jobs.title')}
        description={t('console.automation_jobs.description')}
        columns={[
          t('console.automation_jobs.label'),
          t('console.agents.agent'),
          t('console.session'),
          t('console.automation_jobs.directory'),
          t('console.automation_jobs.failure_wake'),
          t('console.automation_jobs.status'),
          t('console.automation_jobs.created_at')
        ]}
        count={rows.length}
        emptyTitle={t('console.automation_jobs.empty_title')}
        emptyIcon={<RiCodeSSlashLine aria-hidden />}
        emptyDescription={t('console.automation_jobs.empty_description')}
        error={jobs.error}
        isEmpty={rows.length === 0}
        isFiltered={Boolean(query.trim())}
        onClearFilters={() => setQuery('')}
        isLoading={jobs.isLoading}
        toolbarCanRevealRows
        toolbar={
          <ResourceSearch
            label={t('console.automation_jobs.search_placeholder')}
            value={query}
            onChange={setQuery}
            filters={
              <>
                <AgentFilter scope={{ ...scope, selectAgent }} />
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
        <SheetContent closeLabel={t('common.close')} className="w-full data-[side=right]:sm:max-w-[min(64rem,92vw)]">
          <SheetHeader className="gap-3 border-b border-border pb-6">
            <SheetTitle>{detail.data?.automation_job.label ?? t('console.automation_jobs.detail_title')}</SheetTitle>
            <SheetDescription>
              {detail.data?.automation_job ? (
                <span className="font-mono text-xs">
                  #{detail.data.automation_job.id} · {detail.data.automation_job.owner_session_id}
                </span>
              ) : null}
            </SheetDescription>
          </SheetHeader>
          <div className="min-w-0 flex-1 overflow-y-auto px-8 py-6">
            {detailNotFound ? (
              <ErrorBlock error={t('console.automation_jobs.not_found', { id: selectedID })} />
            ) : detail.error ? (
              <ErrorBlock error={detail.error} />
            ) : selectedID !== undefined && !selectedAgentUID && !jobs.isLoading ? (
              <ErrorBlock error={t('console.automation_jobs.not_found', { id: selectedID })} />
            ) : detail.isLoading || !detail.data?.automation_job ? (
              <Skeleton className="h-64 w-full" />
            ) : (
              <AutomationJobDetail job={detail.data.automation_job} />
            )}
          </div>
        </SheetContent>
      </Sheet>
    </>
  )
}

export function automationJobAgentUID(
  jobs: ReadonlyArray<Pick<AutomationJobItem, 'id' | 'agent_uid'>>,
  selectedID: number | undefined,
  scopeAgentUID: string
): string {
  return jobs.find(job => job.id === selectedID)?.agent_uid ?? scopeAgentUID
}

export function automationJobDetailParams(
  current: URLSearchParams,
  job: Pick<AutomationJobItem, 'id' | 'agent_uid'>
): URLSearchParams {
  const next = new URLSearchParams(current)
  next.set('agent', job.agent_uid)
  next.set('job', String(job.id))
  return next
}

export function automationJobScopeParams(current: URLSearchParams, agentUID: string): URLSearchParams {
  const next = new URLSearchParams(current)
  next.delete('job')
  if (agentUID) next.set('agent', agentUID)
  else next.delete('agent')
  return next
}

function AutomationJobRow({ job, onOpen }: { job: AutomationJobItem; onOpen: () => void }) {
  const { t } = useTranslation()

  return (
    <TableRow>
      <TableCell>
        <button type="button" className="grid gap-1 text-left" onClick={onOpen}>
          <span className="font-medium text-foreground hover:text-link hover:underline">{job.label}</span>
          <span className="font-mono text-xs text-muted-foreground">#{job.id}</span>
        </button>
      </TableCell>
      <AgentCell uid={job.agent_uid} />
      <TableCell>
        <span className="block max-w-56 truncate font-mono text-xs" title={job.owner_session_id}>
          {job.owner_session_id}
        </span>
      </TableCell>
      <TableCell>
        <span className="block max-w-80 truncate font-mono text-xs" title={job.directory_path}>
          {job.directory_path}
        </span>
      </TableCell>
      <TableCell>{job.wake_on_failure ? t('common.boolean_true') : t('common.boolean_false')}</TableCell>
      <TableCell>
        <StatusIndicator tone={jobStatusTone(job.status)}>
          {t(`console.automation_jobs.status_${job.status}`)}
        </StatusIndicator>
      </TableCell>
      <TableCell>{formatConsoleDate(job.created_at)}</TableCell>
      <RowViewAction label={t('common.view_details_for', { name: job.label })} onOpen={onOpen} />
    </TableRow>
  )
}

function AutomationJobDetail({ job }: { job: AutomationJobItem }) {
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
          <Fact label={t('console.automation_jobs.directory')} value={job.directory_path} mono />
          <Fact
            label={t('console.automation_jobs.failure_wake')}
            value={job.wake_on_failure ? t('common.boolean_true') : t('common.boolean_false')}
          />
          <Fact label={t('console.automation_jobs.created_at')} value={formatConsoleDate(job.created_at)} />
          <Fact label={t('console.automation_jobs.updated_at')} value={formatConsoleDate(job.updated_at)} />
        </dl>
        <details>
          <summary className="cursor-pointer text-sm font-medium">{t('console.automation_jobs.reply_route')}</summary>
          <pre className="mt-2 max-h-56 overflow-auto border border-border bg-muted p-3 text-xs">
            {formatJSON(job.reply_route)}
          </pre>
        </details>
      </section>

      <section className="grid gap-3">
        <h3 className="font-medium">{t('console.automation_jobs.run_history')}</h3>
        {job.runs.length === 0 ? (
          <p className="text-sm text-muted-foreground">{t('console.automation_jobs.no_runs')}</p>
        ) : (
          job.runs.map(run => <AutomationJobRun key={run.id} run={run} />)
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
        {run.exit_code == null ? null : <span>{t('console.automation_jobs.exit_code', { code: run.exit_code })}</span>}
      </div>
      {run.error ? <p className="break-words text-sm text-destructive">{run.error}</p> : null}
      {run.stdout ? <RunLog label="stdout" value={run.stdout} /> : null}
      {run.stderr ? <RunLog label="stderr" value={run.stderr} /> : null}
    </article>
  )
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

function jobStatusTone(status: AutomationJobItem['status']): 'danger' | 'info' | 'neutral' | 'positive' | 'warning' {
  switch (status) {
    case 'active':
      return 'positive'
    case 'expired':
      return 'warning'
    case 'cancelled':
      return 'neutral'
  }
}

function runStatusTone(status: AutomationJobRunItem['status']): 'danger' | 'info' | 'neutral' | 'positive' | 'warning' {
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
