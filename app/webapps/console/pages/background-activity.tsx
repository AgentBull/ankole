import { useQuery, Link, useSearchParams } from '../tenant-context'
import { Button, Select, SelectContent, SelectItem, SelectTrigger, SelectValue, Skeleton } from '@ankole/uikit'

import type { ReactNode } from 'react'
import { useTranslation } from 'react-i18next'

import { linkTarget } from '../../common/router'
import { requestErrorCode, requestErrorMessage } from '../../common/request-errors'
import {
  backgroundActivityJobsOptions,
  backgroundActivityWorkflowOptions,
  backgroundActivityAutomationRunsOptions
} from '../api/v2/generated/@tanstack/react-query.gen'
import type { AgentItem } from '../api/agents'
import type {
  BackgroundActivityJob,
  BackgroundActivityWorkflowCall,
  BackgroundActivityWorkflowRun,
  BackgroundActivityAutomationRun,
  WorkflowActivityCounts
} from '../api/runtime-types'
import { resolveAgentUID } from '../console-agent-scope'
import { StatusIndicator } from '../console-form'
import { AgentLink, CursorPagination } from '../console-list-page'
import { formatConsoleDate } from '../console-primitives'
import { ACTIVITY_REFRESH_MS } from '../refresh-intervals'
import {
  cursorPageNumber,
  hasPreviousCursor,
  nextCursorParams,
  previousCursorParams,
  resetCursorParams
} from '../state/cursor-pagination'

const key = 'console.home.background_activity.'
const prefixes = ['activity_jobs_', 'activity_calls_', 'activity_runs_', 'activity_automation_']

export function BackgroundActivity({ agents }: { agents: Pick<AgentItem, 'uid' | 'display_name'>[] }) {
  const { t } = useTranslation()
  const [params, setParams] = useSearchParams()
  const uid = resolveAgentUID(agents, params.get('agent') ?? '')
  return (
    <section aria-label={t(`${key}title`)} className="grid gap-4">
      <div className="flex flex-wrap items-center justify-between gap-3">
        <div>
          <h2 className="text-sm font-semibold">{t(`${key}title`)}</h2>
          <p className="mt-1 text-xs text-muted-foreground">{t(`${key}description`)}</p>
        </div>
        <Select
          value={uid || null}
          onValueChange={value =>
            setParams(current => {
              let next = new URLSearchParams(current)
              if (value) next.set('agent', String(value))
              else next.delete('agent')
              for (const prefix of prefixes) next = resetCursorParams(next, prefix)
              return next
            })
          }>
          <SelectTrigger aria-label={t(`${key}agent`)} className="w-64">
            <SelectValue placeholder={t(`${key}choose_agent`)} />
          </SelectTrigger>
          <SelectContent>
            {agents.map(agent => (
              <SelectItem value={agent.uid} key={agent.uid}>
                {agent.display_name}
              </SelectItem>
            ))}
          </SelectContent>
        </Select>
      </div>
      {uid ? (
        <div className="grid items-start gap-4 xl:grid-cols-3">
          <Jobs agentUID={uid} />
          <Workflow agentUID={uid} />
          <Automation agentUID={uid} />
        </div>
      ) : (
        <p className="text-sm text-muted-foreground">{t(`${key}choose_agent`)}</p>
      )}
    </section>
  )
}

function Jobs({ agentUID }: { agentUID: string }) {
  const { t } = useTranslation()
  const [params] = useSearchParams()
  const query = useQuery({
    ...backgroundActivityJobsOptions({
      path: { agent_uid: agentUID },
      query: { limit: 10, cursor: params.get('activity_jobs_cursor') ?? undefined }
    }),
    refetchInterval: ACTIVITY_REFRESH_MS
  })
  const rows = query.data?.jobs ?? []
  return (
    <Group title={t(`${key}jobs`)} query={query}>
      {!rows.length ? <Empty /> : null}
      <ul className="divide-y divide-border">
        {rows.map(row => (
          <JobRow key={row.id} row={row} />
        ))}
      </ul>
      <Paging prefix="activity_jobs_" count={rows.length} next={query.data?.next_cursor} />
    </Group>
  )
}
function Workflow({ agentUID }: { agentUID: string }) {
  const { t } = useTranslation()
  const [params] = useSearchParams()
  const query = useQuery({
    ...backgroundActivityWorkflowOptions({
      path: { agent_uid: agentUID },
      query: {
        limit: 10,
        calls_cursor: params.get('activity_calls_cursor') ?? undefined,
        runs_cursor: params.get('activity_runs_cursor') ?? undefined
      }
    }),
    refetchInterval: ACTIVITY_REFRESH_MS
  })
  const calls = query.data?.live_calls ?? []
  const runs = query.data?.runs ?? []
  return (
    <Group title={t(`${key}workflow`)} query={query}>
      <section aria-label={t(`${key}calls`)} className="border-b border-border">
        <h4 className="px-4 pt-3 text-xs font-medium text-muted-foreground">{t(`${key}calls`)}</h4>
        {!calls.length ? (
          <Empty />
        ) : (
          <ul className="divide-y divide-border">
            {calls.map(row => (
              <CallRow key={row.id} row={row} />
            ))}
          </ul>
        )}
        <Paging prefix="activity_calls_" count={calls.length} next={query.data?.calls_next_cursor} />
      </section>
      <section aria-label={t(`${key}runs`)}>
        <h4 className="px-4 pt-3 text-xs font-medium text-muted-foreground">{t(`${key}runs`)}</h4>
        {!runs.length ? (
          <Empty />
        ) : (
          <ul className="divide-y divide-border">
            {runs.map(row => (
              <RunRow key={row.id} row={row} />
            ))}
          </ul>
        )}
        <Paging prefix="activity_runs_" count={runs.length} next={query.data?.runs_next_cursor} />
      </section>
    </Group>
  )
}
function Automation({ agentUID }: { agentUID: string }) {
  const { t } = useTranslation()
  const [params] = useSearchParams()
  const query = useQuery({
    ...backgroundActivityAutomationRunsOptions({
      path: { agent_uid: agentUID },
      query: { limit: 10, cursor: params.get('activity_automation_cursor') ?? undefined }
    }),
    refetchInterval: ACTIVITY_REFRESH_MS
  })
  const rows = query.data?.runs ?? []
  return (
    <Group title={t(`${key}automation`)} query={query}>
      {!rows.length ? <Empty /> : null}
      <ul className="divide-y divide-border">
        {rows.map(row => (
          <AutomationRow key={row.id} row={row} />
        ))}
      </ul>
      <Paging prefix="activity_automation_" count={rows.length} next={query.data?.next_cursor} />
    </Group>
  )
}

type GroupQuery = { isPending: boolean; error: unknown; data?: { observed_at: string }; refetch: () => unknown }
function Group({ title, query, children }: { title: string; query: GroupQuery; children: ReactNode }) {
  const { t } = useTranslation()
  return (
    <section aria-label={title} className="min-w-0 border border-border bg-card">
      <header className="border-b border-border px-4 py-3">
        <h3 className="text-sm font-semibold">{title}</h3>
        {query.data ? (
          <p className="mt-1 text-xs text-muted-foreground">
            {t(`${key}observed`, { time: formatConsoleDate(query.data.observed_at) })}
          </p>
        ) : null}
      </header>
      {query.error ? (
        <div role="alert" className="space-y-2 p-4 text-sm">
          <p>{requestErrorCode(query.error) === 'forbidden' ? t(`${key}forbidden`) : t(`${key}unavailable`)}</p>
          <p className="text-xs text-muted-foreground">{requestErrorMessage(query.error)}</p>
          <Button variant="outline" size="sm" onClick={() => void query.refetch()}>
            {t('common.retry')}
          </Button>
        </div>
      ) : query.isPending ? (
        <div className="space-y-2 p-4">
          <Skeleton className="h-6 w-full" />
          <Skeleton className="h-6 w-2/3" />
        </div>
      ) : (
        children
      )}
    </section>
  )
}
function Empty() {
  const { t } = useTranslation()
  return <p className="p-4 text-sm text-muted-foreground">{t(`${key}empty`)}</p>
}
function Paging({ prefix, count, next }: { prefix: string; count: number; next?: string | null }) {
  const [params, setParams] = useSearchParams()
  return (
    <div className="px-4 pb-3">
      <CursorPagination
        page={cursorPageNumber(params, prefix)}
        resultCount={count}
        hasPrevious={hasPreviousCursor(params, prefix)}
        nextCursor={next}
        onNext={cursor => setParams(nextCursorParams(params, cursor, prefix))}
        onPrevious={() => setParams(previousCursorParams(params, prefix))}
      />
    </div>
  )
}
function Row({
  kind,
  id,
  title,
  status,
  children
}: {
  kind: string
  id: number
  title: ReactNode
  status: string
  children: ReactNode
}) {
  const { t } = useTranslation()
  return (
    <li className="space-y-2 px-4 py-3 text-xs">
      <div className="flex flex-wrap justify-between gap-2">
        <span className="font-mono text-muted-foreground">
          {t(`${key}${kind}`)} #{id}
        </span>
        <StatusIndicator
          tone={
            status === 'running'
              ? 'info'
              : status === 'waiting_on_user' || status === 'sleeping'
                ? 'waiting'
                : 'neutral'
          }>
          {t(`${key}status_${status}`, { defaultValue: status })}
        </StatusIndicator>
      </div>
      <p className="text-sm font-medium break-words">{title}</p>
      {children}
    </li>
  )
}
function Ownership({ agent, owner, task }: { agent: string; owner: string; task?: string }) {
  const { t } = useTranslation()
  return (
    <dl className="grid grid-cols-[auto_1fr] gap-x-2 gap-y-1 text-muted-foreground">
      <dt>{t(`${key}agent`)}</dt>
      <dd className="break-all">
        <AgentLink uid={agent} />
      </dd>
      <dt>{t(`${key}owner`)}</dt>
      <dd className="font-mono break-all">{owner}</dd>
      {task ? (
        <>
          <dt>{t(`${key}task_session`)}</dt>
          <dd className="font-mono break-all">{task}</dd>
        </>
      ) : null}
    </dl>
  )
}
function Failure({ code, summary }: { code?: string | null; summary?: string | null }) {
  return code || summary ? (
    <p className="break-words text-destructive">
      {code ? `${code}: ` : ''}
      {summary}
    </p>
  ) : null
}
function JobRow({ row }: { row: BackgroundActivityJob }) {
  const { t } = useTranslation()
  return (
    <Row
      kind="job_kind"
      id={row.id}
      title={
        <Link className="hover:underline" {...linkTarget(`/background-agent-jobs?job=${row.id}`)}>
          {row.title}
        </Link>
      }
      status={row.status}>
      <Ownership agent={row.agent_uid} owner={row.owner_session_id} />
      {row.source_signal_id ? (
        <p className="font-mono break-all">
          {t(`${key}source_signal`)}: {row.source_signal_id}
        </p>
      ) : null}
      <p>{t(`${key}attempts`, { count: row.attempts })}</p>
      <Failure code={row.error_code} summary={row.error_summary} />
      <p className="text-muted-foreground">{t(`${key}queued`, { time: formatConsoleDate(row.queued_at) })}</p>
      <p className="text-muted-foreground">{t(`${key}started`, { time: formatConsoleDate(row.started_at) })}</p>
      <p className="text-muted-foreground">{t(`${key}updated`, { time: formatConsoleDate(row.updated_at) })}</p>
    </Row>
  )
}
function CallRow({ row }: { row: BackgroundActivityWorkflowCall }) {
  const { t } = useTranslation()
  return (
    <Row kind="call_kind" id={row.id} title={row.label || `#${row.id}`} status={row.status}>
      <p>
        {t(`${key}parent_run`, {
          id: row.run_id,
          status: t(`${key}status_${row.run_status}`, { defaultValue: row.run_status })
        })}{' '}
        · {row.run_title}
      </p>
      <Ownership agent={row.agent_uid} owner={row.owner_session_id} task={row.task_session_id} />
      {row.attention ? <p className="text-warning">{t(`${key}attention`)}</p> : null}
      {row.sleep_note ? <p className="break-words">{row.sleep_note}</p> : null}
      {row.wake_kind === 'sleep' && row.wake_at ? (
        <p>{t(`${key}sleep_deadline`, { time: formatConsoleDate(row.wake_at) })}</p>
      ) : null}
      <p>{t(`${key}attempts`, { count: row.attempts })}</p>
      <Failure code={row.error_code} summary={row.error_summary} />
      <Failure code={row.run_error_code} summary={row.run_error_summary} />
      <Counts counts={row.run_counts} />
      <p className="text-muted-foreground">{t(`${key}updated`, { time: formatConsoleDate(row.updated_at) })}</p>
    </Row>
  )
}
function RunRow({ row }: { row: BackgroundActivityWorkflowRun }) {
  const { t } = useTranslation()
  return (
    <Row kind="run_kind" id={row.id} title={row.title} status={row.status}>
      <Ownership agent={row.agent_uid} owner={row.owner_session_id} />
      {row.cleanup_pending ? <p className="text-warning">{t(`${key}cleanup_pending`)}</p> : null}
      <Counts counts={row.counts} />
      <Failure code={row.error_code} summary={row.error_summary} />
      <p className="text-muted-foreground">{t(`${key}created`, { time: formatConsoleDate(row.inserted_at) })}</p>
      {row.completed_at ? (
        <p className="text-muted-foreground">{t(`${key}completed`, { time: formatConsoleDate(row.completed_at) })}</p>
      ) : null}
      <p className="text-muted-foreground">{t(`${key}updated`, { time: formatConsoleDate(row.updated_at) })}</p>
    </Row>
  )
}
function Counts({ counts }: { counts: WorkflowActivityCounts }) {
  const { t } = useTranslation()
  return (
    <p className="text-muted-foreground">
      {t(`${key}call_counts`)}:{' '}
      {Object.entries(counts)
        .filter(([status]) => status !== 'total')
        .map(([status, count]) => `${t(`${key}status_${status}`, { defaultValue: status })} ${count}`)
        .join(' · ')}
    </p>
  )
}
function AutomationRow({ row }: { row: BackgroundActivityAutomationRun }) {
  const { t } = useTranslation()
  return (
    <Row
      kind="automation_kind"
      id={row.id}
      title={
        <Link
          className="hover:underline"
          {...linkTarget(`/automation-jobs?agent=${encodeURIComponent(row.agent_uid)}&job=${row.automation_job_id}`)}>
          {row.label || `#${row.automation_job_id}`}
        </Link>
      }
      status={row.status}>
      <p>
        {t(`${key}definition`, {
          id: row.automation_job_id,
          status: t(`${key}status_${row.definition_status}`, { defaultValue: row.definition_status })
        })}
      </p>
      <Ownership agent={row.agent_uid} owner={row.owner_session_id} />
      {row.scheduled_event_id ? (
        <p className="font-mono break-all">
          {t(`${key}scheduled_event`)}: {row.scheduled_event_id}
        </p>
      ) : null}
      <p>{t(`${key}attempts`, { count: row.attempts })}</p>
      {row.attempt_id ? (
        <p className="font-mono break-all">
          {t(`${key}attempt_id`)}: {row.attempt_id}
        </p>
      ) : null}
      <Failure summary={row.error} />
      <p className="text-muted-foreground">{t(`${key}created`, { time: formatConsoleDate(row.inserted_at) })}</p>
      <p className="text-muted-foreground">{t(`${key}started`, { time: formatConsoleDate(row.started_at) })}</p>
      <p className="text-muted-foreground">{t(`${key}updated`, { time: formatConsoleDate(row.updated_at) })}</p>
    </Row>
  )
}
