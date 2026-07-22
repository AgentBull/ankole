import {
  Badge,
  Button,
  Dialog,
  DialogClose,
  DialogContent,
  DialogDescription,
  DialogFooter,
  DialogHeader,
  DialogTitle,
  Empty,
  EmptyContent,
  EmptyDescription,
  EmptyHeader,
  EmptyMedia,
  EmptyTitle,
  Sheet,
  SheetContent,
  SheetDescription,
  SheetFooter,
  SheetHeader,
  SheetTitle,
  Skeleton,
  toast
} from '@ankole/uikit'
import { RiCloseCircleLine, RiTimeLine } from '@remixicon/react'
import { useMutation, useQuery, useQueryClient } from '@tanstack/react-query'
import { type ReactNode, useMemo, useState } from 'react'
import { useTranslation } from 'react-i18next'
import { useSearchParams } from 'react-router'
import { requestErrorMessage } from '../../common/request-errors'
import {
  ankoleWebBackgroundAgentJobControllerCancelMutation,
  ankoleWebBackgroundAgentJobControllerIndexOptions,
  ankoleWebBackgroundAgentJobControllerShowOptions
} from '../api/generated/@tanstack/react-query.gen'
import type { BackgroundAgentJobItem } from '../api/generated/types.gen'
import { ErrorBlock, formatConsoleDate } from '../console-primitives'
import { PageHeader, ResourceSearch, StatusIndicator } from '../console-shell'

type Column = {
  key: 'todo' | 'active' | 'finished'
  statuses: BackgroundAgentJobItem['status'][]
}

type BackgroundAgentJobTurn = NonNullable<BackgroundAgentJobItem['turns']>[number]

const columns: Column[] = [
  { key: 'todo', statuses: ['queued'] },
  { key: 'active', statuses: ['running', 'waiting_on_user'] },
  { key: 'finished', statuses: ['succeeded', 'failed', 'stopped'] }
]

export function BackgroundAgentJobsPage() {
  const { t } = useTranslation()
  const queryClient = useQueryClient()
  const [searchParams, setSearchParams] = useSearchParams()
  const agentFilter = searchParams.get('agent') ?? ''
  const selectedID = backgroundAgentJobID(searchParams.get('job'))
  const [cancelTargetID, setCancelTargetID] = useState<number>()
  const list = useQuery({
    ...ankoleWebBackgroundAgentJobControllerIndexOptions({
      query: { agent: agentFilter.trim() || undefined, limit: 100 }
    }),
    refetchInterval: 5_000
  })
  const detail = useQuery({
    ...ankoleWebBackgroundAgentJobControllerShowOptions({
      path: { job_id: selectedID ?? 1000 }
    }),
    enabled: selectedID !== undefined,
    refetchInterval: selectedID !== undefined ? 5_000 : false,
    retry: false
  })
  const cancel = useMutation({
    ...ankoleWebBackgroundAgentJobControllerCancelMutation(),
    onSuccess: () => {
      toast.success(t('console.background_agent_jobs.cancelled'))
      setCancelTargetID(undefined)
      void queryClient.invalidateQueries()
    },
    onError: error => toast.error(requestErrorMessage(error))
  })
  const jobs = list.data?.jobs ?? []
  const selected = detail.data?.job
  const cancelTarget =
    jobs.find(job => job.id === cancelTargetID) ?? (selected?.id === cancelTargetID ? selected : undefined)

  const setAgentFilter = (value: string) => {
    const next = new URLSearchParams(searchParams)
    if (value) next.set('agent', value)
    else next.delete('agent')
    setSearchParams(next, { replace: true })
  }

  const openBackgroundAgentJob = (id: number) => {
    const next = new URLSearchParams(searchParams)
    next.set('job', String(id))
    setSearchParams(next)
  }

  const closeBackgroundAgentJob = () => {
    const next = new URLSearchParams(searchParams)
    next.delete('job')
    setSearchParams(next, { replace: true })
  }

  const grouped = useMemo(
    () =>
      Object.fromEntries(
        columns.map(column => [column.key, jobs.filter(job => column.statuses.includes(job.status))])
      ) as Record<Column['key'], BackgroundAgentJobItem[]>,
    [jobs]
  )

  return (
    <div className="grid gap-6">
      <PageHeader
        title={t('console.background_agent_jobs.title')}
        description={t('console.background_agent_jobs.description')}
      />
      <ResourceSearch
        label={t('console.background_agent_jobs.agent_filter')}
        placeholder={t('console.background_agent_jobs.agent_filter')}
        value={agentFilter}
        onChange={setAgentFilter}
      />

      {list.error ? (
        <ErrorBlock error={list.error} />
      ) : !list.isLoading && jobs.length === 0 ? (
        <Empty className="items-start border border-border bg-card text-left">
          <EmptyHeader className="items-start">
            <EmptyMedia variant="icon">
              <RiTimeLine aria-hidden />
            </EmptyMedia>
            <EmptyTitle>
              {agentFilter ? t('console.empty.no_results_title') : t('console.background_agent_jobs.empty_title')}
            </EmptyTitle>
            <EmptyDescription>
              {agentFilter
                ? t('console.empty.no_results_description')
                : t('console.background_agent_jobs.empty_description')}
            </EmptyDescription>
          </EmptyHeader>
          {agentFilter ? (
            <EmptyContent className="items-start">
              <Button type="button" size="sm" variant="outline" onClick={() => setAgentFilter('')}>
                {t('console.empty.clear_search')}
              </Button>
            </EmptyContent>
          ) : null}
        </Empty>
      ) : (
        <div className="grid min-w-0 gap-4 xl:grid-cols-3">
          {columns.map(column => (
            <section key={column.key} className="min-h-72 border border-border bg-muted/25">
              <header className="flex items-center justify-between border-b border-border bg-card px-4 py-3">
                <h3 className="font-medium">{t(`console.background_agent_jobs.column_${column.key}`)}</h3>
                <Badge variant="secondary">{grouped[column.key].length}</Badge>
              </header>
              <div className="grid gap-3 p-3">
                {list.isLoading ? (
                  <>
                    <Skeleton className="h-36 w-full" />
                    <Skeleton className="h-28 w-full" />
                  </>
                ) : grouped[column.key].length === 0 ? (
                  <p className="px-2 py-8 text-center text-sm text-muted-foreground">
                    {t('console.background_agent_jobs.empty_column')}
                  </p>
                ) : (
                  grouped[column.key].map(task => (
                    <BackgroundAgentJobCard
                      key={task.id}
                      task={task}
                      cancelling={cancel.isPending}
                      onCancel={() => setCancelTargetID(task.id)}
                      onOpen={() => openBackgroundAgentJob(task.id)}
                    />
                  ))
                )}
              </div>
            </section>
          ))}
        </div>
      )}

      <Sheet open={selectedID !== undefined} onOpenChange={open => !open && closeBackgroundAgentJob()}>
        <SheetContent className="w-full sm:max-w-2xl">
          <SheetHeader>
            <SheetTitle>{selected?.title ?? t('console.background_agent_jobs.detail_title')}</SheetTitle>
            <SheetDescription>{selected ? `${selected.agent_uid} · ${selected.id}` : ''}</SheetDescription>
          </SheetHeader>

          <div className="grid flex-1 gap-6 overflow-y-auto px-8 pb-8">
            {detail.error ? (
              <ErrorBlock error={detail.error} />
            ) : detail.isLoading || !selected ? (
              <Skeleton className="h-64 w-full" />
            ) : (
              <>
                <dl className="grid grid-cols-2 gap-x-6 gap-y-3 border border-border bg-card p-4 text-sm">
                  <DetailField
                    label={t('console.background_agent_jobs.status')}
                    value={<StatusBadge status={selected.status} />}
                  />
                  <DetailField
                    label={t('console.background_agent_jobs.codex_account')}
                    value={selected.codex_account_id}
                  />
                  <DetailField label={t('console.background_agent_jobs.attempts')} value={String(selected.attempts)} />
                  <DetailField
                    label={t('console.background_agent_jobs.duration')}
                    value={formatDuration(selected.duration_seconds)}
                  />
                  <DetailField
                    label={t('console.background_agent_jobs.workspace_template')}
                    value={selected.workspace_template_id ?? '—'}
                    wide
                  />
                  <DetailField label={t('console.background_agent_jobs.task')} value={selected.task ?? '—'} wide />
                  <DetailField
                    label={t('console.background_agent_jobs.trajectory_integrity')}
                    value={turnsSummary(selected.turns)}
                    wide
                  />
                  <DetailField
                    label={t('console.background_agent_jobs.result')}
                    value={summary(selected.status === 'failed' ? selected.error : selected.result)}
                    wide
                  />
                </dl>

                <section className="grid gap-3">
                  <h3 className="font-medium">{t('console.background_agent_jobs.timeline')}</h3>
                  {selected.turns?.length ? (
                    <div className="grid gap-5">
                      {groupTurnsByAttempt(selected.turns, selected.attempts, selected.runtime_thread_id).map(group => (
                        <section key={group.attempt} className="grid gap-2">
                          <h4 className="text-xs font-medium text-muted-foreground">
                            {t('console.background_agent_jobs.attempt_label', { count: group.attempt })}
                          </h4>
                          <ol className="grid gap-3 border-l border-border pl-5">
                            {group.turns.map(turn => (
                              <li key={turn.id} className="relative grid gap-3 border border-border bg-card p-3">
                                <span className="absolute top-4 -left-[1.43rem] size-2.5 rounded-full bg-primary" />
                                <div className="flex flex-wrap items-center justify-between gap-2">
                                  <span className="break-all font-mono text-xs">
                                    {turn.kind} · {turn.runtime_turn_id}
                                  </span>
                                  <span className="text-xs text-muted-foreground">
                                    {formatConsoleDate(turn.started_at)}
                                  </span>
                                </div>
                                <div className="flex flex-wrap gap-2 text-xs text-muted-foreground">
                                  <Badge variant="outline">
                                    {t(
                                      turn.runtime_thread_id === group.leadThreadID
                                        ? 'console.background_agent_jobs.turn_scope_lead'
                                        : 'console.background_agent_jobs.turn_scope_child'
                                    )}
                                  </Badge>
                                  <Badge variant="secondary">{turn.status}</Badge>
                                  <span>revision={turn.revision}</span>
                                  <span>{turn.trajectory.messages.length} messages</span>
                                  {turn.trajectory.metadata?.redacted ? <span>redacted</span> : null}
                                  {turn.trajectory.metadata?.content_truncated ? (
                                    <span>
                                      truncated
                                      {turn.trajectory.metadata.omitted_items
                                        ? ` · ${turn.trajectory.metadata.omitted_items} items omitted`
                                        : ''}
                                    </span>
                                  ) : null}
                                </div>
                                <TurnRuntimeSnapshot turn={turn} />
                                <div className="grid gap-2">
                                  {turn.trajectory.messages.map((message, index) => (
                                    <article key={`${turn.id}:${index}`} className="grid gap-1 bg-muted p-2 text-xs">
                                      <span className="font-medium">{trajectoryMessageLabel(message)}</span>
                                      <pre className="max-h-48 overflow-auto whitespace-pre-wrap break-words font-sans">
                                        {trajectoryMessageText(message)}
                                      </pre>
                                    </article>
                                  ))}
                                </div>
                              </li>
                            ))}
                          </ol>
                        </section>
                      ))}
                    </div>
                  ) : (
                    <p className="text-sm text-muted-foreground">{t('console.background_agent_jobs.no_turns')}</p>
                  )}
                </section>
              </>
            )}
          </div>

          {selected && cancellable(selected.status) ? (
            <SheetFooter>
              <Button variant="destructive" disabled={cancel.isPending} onClick={() => setCancelTargetID(selected.id)}>
                <RiCloseCircleLine />
                {t('console.background_agent_jobs.cancel')}
              </Button>
            </SheetFooter>
          ) : null}
        </SheetContent>
      </Sheet>

      <Dialog open={Boolean(cancelTarget)} onOpenChange={open => !open && setCancelTargetID(undefined)}>
        <DialogContent>
          <DialogHeader>
            <DialogTitle>{t('console.background_agent_jobs.cancel_title')}</DialogTitle>
            <DialogDescription>
              {t('console.background_agent_jobs.cancel_confirm', {
                title: cancelTarget?.title ?? cancelTarget?.id ?? ''
              })}
            </DialogDescription>
          </DialogHeader>
          <DialogFooter>
            <DialogClose render={<Button variant="outline" />}>{t('common.cancel')}</DialogClose>
            <Button
              variant="destructive"
              disabled={!cancelTarget || cancel.isPending}
              onClick={() => cancelTarget && cancel.mutate({ path: { job_id: cancelTarget.id } })}>
              {t('console.background_agent_jobs.cancel')}
            </Button>
          </DialogFooter>
        </DialogContent>
      </Dialog>
    </div>
  )
}

function BackgroundAgentJobCard({
  task,
  cancelling,
  onCancel,
  onOpen
}: {
  task: BackgroundAgentJobItem
  cancelling: boolean
  onCancel: () => void
  onOpen: () => void
}) {
  const { t } = useTranslation()

  return (
    <article className="grid gap-3 border border-border bg-card p-4 shadow-xs transition-colors hover:border-foreground/30">
      <button
        type="button"
        className="grid gap-3 text-left outline-none focus-visible:ring-2 focus-visible:ring-ring/40"
        aria-label={t('console.background_agent_jobs.open_detail', { title: task.title ?? task.id })}
        onClick={onOpen}>
        <div className="flex items-start justify-between gap-3">
          <h4 className="line-clamp-2 font-medium leading-5">{task.title ?? task.id}</h4>
          <StatusBadge status={task.status} />
        </div>
        <div className="grid gap-1 text-xs text-muted-foreground">
          <span className="truncate font-mono">{task.agent_uid}</span>
          <span className="flex items-center gap-1.5">
            <RiTimeLine className="size-3.5" />
            {formatDuration(task.duration_seconds)} ·{' '}
            {t('console.background_agent_jobs.attempt_count', { count: task.attempts })}
          </span>
          <span>{task.workspace_template_id ?? t('console.background_agent_jobs.no_workspace_template')}</span>
        </div>
      </button>
      {cancellable(task.status) ? (
        <Button size="xs" variant="outline" disabled={cancelling} onClick={onCancel}>
          {t('console.background_agent_jobs.cancel')}
        </Button>
      ) : null}
    </article>
  )
}

function StatusBadge({ status }: { status: BackgroundAgentJobItem['status'] }) {
  const { t } = useTranslation()
  const tone =
    status === 'failed' || status === 'stopped'
      ? 'danger'
      : status === 'succeeded'
        ? 'positive'
        : status === 'running'
          ? 'info'
          : status === 'waiting_on_user'
            ? 'warning'
            : 'neutral'
  return <StatusIndicator tone={tone}>{t(`console.background_agent_jobs.status_${status}`)}</StatusIndicator>
}

function DetailField({ label, value, wide = false }: { label: string; value: ReactNode; wide?: boolean }) {
  return (
    <div className={wide ? 'col-span-2 grid gap-1' : 'grid gap-1'}>
      <dt className="text-xs text-muted-foreground">{label}</dt>
      <dd className="whitespace-pre-wrap break-words">{value}</dd>
    </div>
  )
}

function TurnRuntimeSnapshot({ turn }: { turn: BackgroundAgentJobTurn }) {
  const { t } = useTranslation()
  const tools = turn.progress.tools_used.map(tool => `${tool.name} ×${tool.calls}`).join(', ') || '—'
  const files = turn.progress.files_changed.join('\n') || '—'
  const plan = turn.progress.plan
  const planText = plan
    ? [plan.explanation, ...plan.steps.map(step => `[${step.status}] ${step.step}`)]
        .filter((line): line is string => Boolean(line))
        .join('\n')
    : '—'

  return (
    <dl className="grid gap-2 border-y border-border py-3 text-xs sm:grid-cols-2">
      <SnapshotField
        label={t('console.background_agent_jobs.completed_items')}
        value={String(turn.progress.completed_items)}
      />
      <SnapshotField label={t('console.background_agent_jobs.tool_calls')} value={String(turn.progress.tool_calls)} />
      <SnapshotField label={t('console.background_agent_jobs.tools_used')} value={tools} />
      <SnapshotField label={t('console.background_agent_jobs.token_usage')} value={tokenUsageSummary(turn.usage)} />
      <SnapshotField
        label={t('console.background_agent_jobs.active_item')}
        value={turn.progress.active_item ? `${turn.progress.active_item.name} (${turn.progress.active_item.id})` : '—'}
      />
      <SnapshotField label={t('console.background_agent_jobs.plan')} value={planText} />
      <SnapshotField label={t('console.background_agent_jobs.files_changed')} value={files} wide />
    </dl>
  )
}

function SnapshotField({ label, value, wide = false }: { label: string; value: string; wide?: boolean }) {
  return (
    <div className={wide ? 'grid gap-1 sm:col-span-2' : 'grid gap-1'}>
      <dt className="text-muted-foreground">{label}</dt>
      <dd className="whitespace-pre-wrap break-all font-mono">{value}</dd>
    </div>
  )
}

function tokenUsageSummary(usage: BackgroundAgentJobTurn['usage']): string {
  if (!usage) return '—'
  const total = usage.thread_total
  const last = usage.last_model_call
  const context = usage.model_context_window === undefined ? '' : ` · context=${usage.model_context_window}`
  return [
    `thread: total=${total.total_tokens} · input=${total.input_tokens} · cached=${total.cached_input_tokens} · output=${total.output_tokens} · reasoning=${total.reasoning_output_tokens}${context}`,
    `last call: total=${last.total_tokens} · input=${last.input_tokens} · cached=${last.cached_input_tokens} · output=${last.output_tokens} · reasoning=${last.reasoning_output_tokens}`
  ].join('\n')
}

function groupTurnsByAttempt(
  turns: BackgroundAgentJobTurn[],
  currentAttempt: number,
  currentLeadThreadID?: string | null
) {
  const groups = new Map<number, BackgroundAgentJobTurn[]>()
  for (const turn of turns) {
    groups.set(turn.attempt, [...(groups.get(turn.attempt) ?? []), turn])
  }
  return [...groups.entries()]
    .sort(([left], [right]) => left - right)
    .map(([attempt, attemptTurns]) => ({
      attempt,
      turns: attemptTurns,
      leadThreadID:
        (attempt === currentAttempt && attemptTurns.some(turn => turn.runtime_thread_id === currentLeadThreadID)
          ? currentLeadThreadID
          : attemptTurns.find(turn => turn.kind === 'agent')?.runtime_thread_id) ?? attemptTurns[0]?.runtime_thread_id
    }))
}

function cancellable(status: BackgroundAgentJobItem['status']): boolean {
  return status === 'queued' || status === 'running' || status === 'waiting_on_user'
}

function backgroundAgentJobID(value: string | null): number | undefined {
  if (!value || !/^[1-9][0-9]*$/.test(value)) return undefined

  const id = Number(value)
  return Number.isSafeInteger(id) && id >= 1000 ? id : undefined
}

function formatDuration(seconds: number): string {
  if (seconds < 60) return `${seconds}s`
  if (seconds < 3_600) return `${Math.floor(seconds / 60)}m`
  if (seconds < 86_400) return `${Math.floor(seconds / 3_600)}h ${Math.floor((seconds % 3_600) / 60)}m`
  return `${Math.floor(seconds / 86_400)}d ${Math.floor((seconds % 86_400) / 3_600)}h`
}

function summary(value: Record<string, unknown>): string {
  for (const key of ['summary', 'output_text', 'message', 'reason', 'code']) {
    if (typeof value[key] === 'string' && value[key]) return String(value[key])
  }
  return Object.keys(value).length ? truncate(JSON.stringify(value, null, 2), 4_000) : '—'
}

function turnsSummary(turns: BackgroundAgentJobItem['turns']): string {
  if (!turns?.length) return '—'
  const latest = turns.at(-1)!
  const integrity = [
    latest.trajectory.metadata?.redacted ? 'redacted' : undefined,
    latest.trajectory.metadata?.content_truncated ? 'truncated' : undefined
  ].filter(Boolean)
  return [
    `turns=${turns.length}`,
    `latest=${latest.status}`,
    `format=${latest.trajectory.format}@${latest.trajectory.version}`,
    integrity.length ? `integrity=${integrity.join(',')}` : undefined
  ]
    .filter(Boolean)
    .join('\n')
}

function trajectoryMessageLabel(value: Record<string, unknown>): string {
  const role = typeof value.role === 'string' ? value.role : 'message'
  const name = typeof value.name === 'string' ? ` · ${value.name}` : ''
  return `${role}${name}`
}

function trajectoryMessageText(value: Record<string, unknown>): string {
  return JSON.stringify(value, null, 2)
}

function truncate(value: string, limit: number): string {
  return value.length <= limit ? value : `${value.slice(0, limit)}…`
}
