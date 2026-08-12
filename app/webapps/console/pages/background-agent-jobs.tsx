import {
  Accordion,
  AccordionContent,
  AccordionItem,
  AccordionTrigger,
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
  Textarea,
  cn,
  toast
} from '@ankole/uikit'
import {
  RiCheckboxBlankCircleLine,
  RiCheckboxCircleFill,
  RiCloseCircleLine,
  RiCodeSSlashLine,
  RiFileTextLine,
  RiProgress3Line,
  RiRobot2Line,
  RiTerminalBoxLine,
  RiTimeLine,
  RiUser3Line
} from '@remixicon/react'
import { match } from '@agentbull/active-support'
import { keepPreviousData, useMutation, useQuery, useQueryClient } from '@tanstack/react-query'
import { type ReactNode, useMemo, useState } from 'react'
import { useTranslation } from 'react-i18next'
import { useSearchParams } from 'react-router'
import { requestErrorMessage } from '../../common/request-errors'
import {
  ankoleWebBackgroundAgentJobControllerCancelMutation,
  ankoleWebBackgroundAgentJobControllerCompleteMutation,
  ankoleWebBackgroundAgentJobControllerHealthOptions,
  ankoleWebBackgroundAgentJobControllerIndexOptions,
  ankoleWebBackgroundAgentJobControllerShowOptions
} from '../api/generated/@tanstack/react-query.gen'
import type {
  BackgroundAgentJobHealthResponse,
  BackgroundAgentJobItem,
  BackgroundAgentJobListItem,
  BackgroundAgentJobTurnPlanStep,
  BackgroundAgentJobTurnUsageBreakdown
} from '../api/generated/types.gen'
import { AgentFilter, useAgentScope } from '../console-agent-scope'
import { ErrorBlock } from '../../common/error-block'
import { formatConsoleDate, formatJSON } from '../console-primitives'
import { resourceID } from '../console-route-loaders'
import { MarkdownBody } from '../markdown-body'
import { StatusIndicator } from '../console-form'
import { ScopeBar } from '../console-list-page'
import { PageHeader, PageStack, RefreshButton } from '../console-page'

type JobStatus = BackgroundAgentJobItem['status']

type Column = {
  key: 'todo' | 'active' | 'finished'
  statuses: JobStatus[]
}

type BackgroundAgentJobTurn = NonNullable<BackgroundAgentJobItem['turns']>[number]

type TrajectoryMessage = BackgroundAgentJobTurn['trajectory']['messages'][number]

const columns: Column[] = [
  { key: 'todo', statuses: ['queued'] },
  { key: 'active', statuses: ['running', 'waiting_on_user'] },
  { key: 'finished', statuses: ['succeeded', 'failed', 'stopped'] }
]

export function BackgroundAgentJobsPage() {
  const { t } = useTranslation()
  const queryClient = useQueryClient()
  const [searchParams, setSearchParams] = useSearchParams()
  const scope = useAgentScope()
  const selectedID = resourceID(searchParams.get('job'))
  const [cancelTargetID, setCancelTargetID] = useState<number>()
  const [completeTargetID, setCompleteTargetID] = useState<number>()
  const [completeSummary, setCompleteSummary] = useState('')
  const health = useQuery({
    ...ankoleWebBackgroundAgentJobControllerHealthOptions(),
    refetchInterval: 15_000
  })
  // This list endpoint spans agents on its own; the scope only narrows it.
  const list = useQuery({
    ...ankoleWebBackgroundAgentJobControllerIndexOptions({
      query: { agent: scope.agentUID || undefined, limit: 100 }
    }),
    placeholderData: keepPreviousData,
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
  const complete = useMutation({
    ...ankoleWebBackgroundAgentJobControllerCompleteMutation(),
    onSuccess: () => {
      toast.success(t('console.background_agent_jobs.completed'))
      setCompleteTargetID(undefined)
      setCompleteSummary('')
      void queryClient.invalidateQueries()
    },
    onError: error => toast.error(requestErrorMessage(error))
  })
  const jobs = list.data?.jobs ?? []
  const selected = detail.data?.job
  const cancelTarget =
    jobs.find(job => job.id === cancelTargetID) ?? (selected?.id === cancelTargetID ? selected : undefined)

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
      ) as Record<Column['key'], BackgroundAgentJobListItem[]>,
    [jobs]
  )

  return (
    <PageStack>
      <PageHeader
        title={t('console.background_agent_jobs.title')}
        description={t('console.background_agent_jobs.description')}
        actions={<RefreshButton />}
      />
      <ScopeBar>
        <AgentFilter scope={scope} />
      </ScopeBar>

      {health.data ? <JobHealthStrip health={health.data} /> : null}

      {list.error ? (
        <ErrorBlock error={list.error} />
      ) : !list.isLoading && jobs.length === 0 ? (
        <Empty className="items-start border border-border bg-card text-left">
          <EmptyHeader className="items-start">
            <EmptyMedia variant="icon">
              <RiTimeLine aria-hidden />
            </EmptyMedia>
            <EmptyTitle>
              {scope.agentUID ? t('console.empty.no_results_title') : t('console.background_agent_jobs.empty_title')}
            </EmptyTitle>
            <EmptyDescription>
              {scope.agentUID
                ? t('console.empty.no_results_description')
                : t('console.background_agent_jobs.empty_description')}
            </EmptyDescription>
          </EmptyHeader>
          {scope.agentUID ? (
            <EmptyContent className="items-start">
              <Button type="button" size="sm" variant="outline" onClick={() => scope.selectAgent('')}>
                {t('console.empty.clear_filters')}
              </Button>
            </EmptyContent>
          ) : null}
        </Empty>
      ) : (
        <div className="grid grid-cols-1 min-w-0 gap-4 xl:grid-cols-3">
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

      {/* The board reads one page and the finished column grows without bound, so
          a busy Installation silently loses its older jobs off the end. Say that
          the view is capped rather than let it look complete. */}
      {list.data?.next_cursor ? (
        <p className="text-sm text-muted-foreground">
          {t('console.background_agent_jobs.capped', { count: jobs.length })}
        </p>
      ) : null}

      {/*
        The width override must repeat the `data-[side=right]:sm:` variant of the
        uikit default. A bare `sm:max-w-*` loses to it on specificity — the
        attribute selector wins — so the panel silently stayed at `max-w-sm`.
      */}
      <Sheet open={selectedID !== undefined} onOpenChange={open => !open && closeBackgroundAgentJob()}>
        <SheetContent closeLabel={t('common.close')} className="w-full data-[side=right]:sm:max-w-[min(80rem,92vw)]">
          <SheetHeader className="gap-3 border-b border-border pb-6">
            <div className="flex min-w-0 flex-wrap items-center gap-x-3 gap-y-2 pr-10">
              <SheetTitle className="min-w-0 break-words">
                {selected?.title ?? t('console.background_agent_jobs.detail_title')}
              </SheetTitle>
              {selected ? <StatusBadge status={selected.status} /> : null}
            </div>
            <SheetDescription className="flex flex-wrap items-center gap-x-2 gap-y-1">
              {selected ? (
                <>
                  <span className="break-all font-mono text-xs">{selected.agent_uid}</span>
                  <span aria-hidden>·</span>
                  <span className="font-mono text-xs">#{selected.id}</span>
                  <span aria-hidden>·</span>
                  <span>{formatDuration(selected.duration_seconds)}</span>
                </>
              ) : null}
            </SheetDescription>
          </SheetHeader>

          <div className="min-w-0 flex-1 overflow-y-auto px-8 py-6">
            {detail.error ? (
              <ErrorBlock error={detail.error} />
            ) : detail.isLoading || !selected ? (
              <Skeleton className="h-64 w-full" />
            ) : (
              <div className="grid grid-cols-1 min-w-0 gap-8 xl:grid-cols-[18rem_minmax(0,1fr)] xl:gap-10">
                <JobFacts job={selected} />
                <div className="grid min-w-0 gap-8">
                  <JobPrompt job={selected} />
                  <JobOutcome job={selected} />
                  <JobTrajectory job={selected} />
                </div>
              </div>
            )}
          </div>

          {selected && cancellable(selected.status) ? (
            <SheetFooter>
              <Button variant="outline" disabled={complete.isPending} onClick={() => setCompleteTargetID(selected.id)}>
                <RiCheckboxCircleFill />
                {t('console.background_agent_jobs.complete')}
              </Button>
              <Button variant="destructive" disabled={cancel.isPending} onClick={() => setCancelTargetID(selected.id)}>
                <RiCloseCircleLine />
                {t('console.background_agent_jobs.cancel')}
              </Button>
            </SheetFooter>
          ) : null}
        </SheetContent>
      </Sheet>

      <Dialog
        open={completeTargetID !== undefined}
        onOpenChange={open => {
          if (!open) {
            setCompleteTargetID(undefined)
            setCompleteSummary('')
          }
        }}>
        <DialogContent closeLabel={t('common.close')}>
          <DialogHeader>
            <DialogTitle>{t('console.background_agent_jobs.complete_title')}</DialogTitle>
            <DialogDescription>{t('console.background_agent_jobs.complete_confirm')}</DialogDescription>
          </DialogHeader>
          <Textarea
            value={completeSummary}
            rows={4}
            placeholder={t('console.background_agent_jobs.complete_summary_placeholder')}
            onChange={event => setCompleteSummary(event.target.value)}
          />
          <DialogFooter>
            <DialogClose render={<Button variant="outline" />}>{t('common.cancel')}</DialogClose>
            <Button
              disabled={completeTargetID === undefined || !completeSummary.trim() || complete.isPending}
              onClick={() =>
                completeTargetID !== undefined &&
                complete.mutate({
                  path: { job_id: completeTargetID },
                  body: { result_summary: completeSummary.trim() }
                })
              }>
              {t('console.background_agent_jobs.complete')}
            </Button>
          </DialogFooter>
        </DialogContent>
      </Dialog>

      <Dialog open={Boolean(cancelTarget)} onOpenChange={open => !open && setCancelTargetID(undefined)}>
        <DialogContent closeLabel={t('common.close')}>
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
    </PageStack>
  )
}

/**
 * The four reliability signals from the 2026-08-12 incident review: queue
 * starvation, infrastructure churn against charged failures, terminal-steer
 * conversion, and delivery degradation. Ratios render beside their raw counts
 * so an empty denominator reads as "no data" instead of a fake 0%.
 */
function JobHealthStrip({ health }: { health: BackgroundAgentJobHealthResponse }) {
  const { t } = useTranslation()
  const ratio = (numerator: number, denominator: number) =>
    denominator > 0 ? `${Math.round((numerator / denominator) * 100)}%` : '—'

  const cells: { key: string; value: string; hint: string }[] = [
    {
      key: 'oldest_queued',
      value: health.oldest_queued_seconds === null ? '—' : formatDuration(health.oldest_queued_seconds),
      hint: t('console.background_agent_jobs.health_oldest_queued_hint', {
        queued: health.queued_count,
        running: health.running_count
      })
    },
    {
      key: 'failure_ratio',
      value: ratio(health.execution_failures_24h, health.claims_24h),
      hint: t('console.background_agent_jobs.health_failure_ratio_hint', {
        failures: health.execution_failures_24h,
        claims: health.claims_24h
      })
    },
    {
      key: 'successor_rate',
      value: ratio(health.successor_seeded_24h, health.succeeded_24h),
      hint: t('console.background_agent_jobs.health_successor_rate_hint', {
        seeded: health.successor_seeded_24h,
        succeeded: health.succeeded_24h
      })
    },
    {
      key: 'dead_letter_rate',
      value: ratio(health.dead_letter_notices_24h, health.wakeups_24h),
      hint: t('console.background_agent_jobs.health_dead_letter_rate_hint', {
        notices: health.dead_letter_notices_24h,
        wakeups: health.wakeups_24h
      })
    }
  ]

  return (
    <div className="grid grid-cols-2 gap-3 lg:grid-cols-4">
      {cells.map(cell => (
        <div key={cell.key} className="border border-border bg-card px-4 py-3">
          <p className="text-xs text-muted-foreground">{t(`console.background_agent_jobs.health_${cell.key}`)}</p>
          <p className="mt-1 text-xl font-medium tabular-nums">{cell.value}</p>
          <p className="mt-1 text-xs text-muted-foreground">{cell.hint}</p>
        </div>
      ))}
    </div>
  )
}

function BackgroundAgentJobCard({
  task,
  cancelling,
  onCancel,
  onOpen
}: {
  task: BackgroundAgentJobListItem
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
        {/* A title that is one long unbreakable identifier used to set the
            minimum width of the whole column: every card in it grew past the
            column border and the board gained a horizontal scrollbar. `min-w-0`
            keeps the row shrinkable and `break-words` lets the identifier wrap
            into the two clamped lines instead of demanding its full width. */}
        <div className="flex min-w-0 items-start justify-between gap-3">
          {/* Two lines then an ellipsis often cuts the identifier the title ends
              with, and the card is the only place that identifier appears. */}
          <h4 className="line-clamp-2 min-w-0 font-medium break-words leading-5" title={task.title ?? String(task.id)}>
            {task.title ?? task.id}
          </h4>
          {/* A column that holds one status has already said it. The badge earns
              its place only where the column mixes several. */}
          {distinguishesStatus(task.status) ? <StatusBadge status={task.status} /> : null}
        </div>
        <div className="grid gap-1 text-xs text-muted-foreground">
          <span className="truncate font-mono">{task.agent_uid}</span>
          <span className="flex items-center gap-1.5">
            <RiTimeLine className="size-3.5" />
            {formatDuration(task.duration_seconds)} ·{' '}
            {t('console.background_agent_jobs.attempt_count', { count: task.attempts })}
          </span>
          {task.workspace_template_id ? <span className="truncate">{task.workspace_template_id}</span> : null}
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

function StatusBadge({ status }: { status: JobStatus }) {
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

/**
 * Facts rail: the short scalar attributes of the job. It sticks to the top of
 * the scroll container on wide viewports so the status and account stay visible
 * while the reader walks a long trajectory.
 */
function JobFacts({ job }: { job: BackgroundAgentJobItem }) {
  const { t } = useTranslation()

  return (
    <dl
      aria-label={t('console.background_agent_jobs.overview')}
      className="grid grid-cols-1 min-w-0 content-start gap-px self-start border border-border bg-border sm:grid-cols-2 lg:grid-cols-3 xl:sticky xl:top-0 xl:grid-cols-1">
      <Fact label={t('console.background_agent_jobs.status')} value={<StatusBadge status={job.status} />} />
      <Fact label={t('console.background_agent_jobs.agent')} value={job.agent_uid} mono />
      <Fact label={t('console.background_agent_jobs.model_profile')} value={job.model_profile} mono />
      <Fact
        label={t('console.background_agent_jobs.workspace_template')}
        value={job.workspace_template_id ?? '—'}
        mono
      />
      <Fact label={t('console.background_agent_jobs.attempts')} value={job.attempts} />
      <Fact label={t('console.background_agent_jobs.turns')} value={job.turns?.length ?? 0} />
      <Fact label={t('console.background_agent_jobs.duration')} value={formatDuration(job.duration_seconds)} />
      <Fact label={t('console.background_agent_jobs.queued_at')} value={formatConsoleDate(job.queued_at)} />
      <Fact label={t('console.background_agent_jobs.started_at')} value={formatConsoleDate(job.started_at)} />
      <Fact label={t('console.background_agent_jobs.completed_at')} value={formatConsoleDate(job.completed_at)} />
    </dl>
  )
}

function Fact({ label, value, mono = false }: { label: string; value: ReactNode; mono?: boolean }) {
  return (
    <div className="grid content-start gap-1 bg-card px-4 py-3">
      <dt className="text-xs text-muted-foreground">{label}</dt>
      <dd className={cn('break-all text-sm', mono && 'font-mono text-xs leading-5')}>{value}</dd>
    </div>
  )
}

function JobSection({ title, aside, children }: { title: string; aside?: ReactNode; children: ReactNode }) {
  return (
    <section className="grid min-w-0 gap-3">
      <div className="flex flex-wrap items-center gap-x-3 gap-y-2">
        <h3 className="text-base font-semibold">{title}</h3>
        {aside}
      </div>
      {children}
    </section>
  )
}

/** The instruction the job was queued with. Long prompts read as flowing text, not a clipped cell. */
function JobPrompt({ job }: { job: BackgroundAgentJobItem }) {
  const { t } = useTranslation()

  return (
    <JobSection title={t('console.background_agent_jobs.task')}>
      <div className="border border-border bg-card px-4 py-3 text-sm leading-6 whitespace-pre-wrap break-words">
        {job.task || '—'}
      </div>
    </JobSection>
  )
}

/**
 * Result on success, error payload on failure. Both are freeform objects, so a
 * known text field renders as prose and anything else falls back to indented
 * JSON rather than a single squeezed line.
 */
function JobOutcome({ job }: { job: BackgroundAgentJobItem }) {
  const { t } = useTranslation()
  const failed = job.status === 'failed'
  const payload = failed ? job.error : job.result
  if (Object.keys(payload).length === 0) return null

  const text = outcomeText(payload)

  return (
    <JobSection
      title={t(failed ? 'console.background_agent_jobs.error' : 'console.background_agent_jobs.result')}
      aside={failed ? <StatusIndicator tone="danger">{job.status}</StatusIndicator> : undefined}>
      {text ? (
        <div
          className={cn(
            'border border-border px-4 py-3 text-sm leading-6 whitespace-pre-wrap break-words',
            failed ? 'border-destructive/40 bg-destructive/5' : 'bg-card'
          )}>
          {text}
        </div>
      ) : (
        <CodeBlock>{truncate(formatJSON(payload), 8_000)}</CodeBlock>
      )}
    </JobSection>
  )
}

/** Recorded runtime Turns, grouped by attempt so a retried job stays legible. */
function JobTrajectory({ job }: { job: BackgroundAgentJobItem }) {
  const { t } = useTranslation()
  const latest = job.turns?.at(-1)

  if (!job.turns?.length) {
    return (
      <JobSection title={t('console.background_agent_jobs.timeline')}>
        <p className="border border-border bg-card px-4 py-8 text-center text-sm text-muted-foreground">
          {t('console.background_agent_jobs.no_turns')}
        </p>
      </JobSection>
    )
  }

  return (
    <JobSection
      title={t('console.background_agent_jobs.timeline')}
      aside={<IntegrityBadges metadata={latest?.trajectory.metadata} />}>
      <div className="grid gap-6">
        {groupTurnsByAttempt(job.turns, job.attempts, job.runtime_thread_id).map(group => (
          <section key={group.attempt} className="grid min-w-0 gap-3">
            <h4 className="text-xs font-medium tracking-wide text-muted-foreground uppercase">
              {t('console.background_agent_jobs.attempt_label', { count: group.attempt })}
            </h4>
            <ol className="grid min-w-0 gap-4 border-l border-border pl-6">
              {group.turns.map(turn => (
                <TurnCard key={turn.id} turn={turn} lead={turn.runtime_thread_id === group.leadThreadID} />
              ))}
            </ol>
          </section>
        ))}
      </div>
    </JobSection>
  )
}

/** Warns that the stored trajectory is not the whole story before anyone reads it as one. */
function IntegrityBadges({ metadata }: { metadata: BackgroundAgentJobTurn['trajectory']['metadata'] }) {
  const { t } = useTranslation()
  if (!metadata?.redacted && !metadata?.content_truncated) return null

  return (
    <span className="flex flex-wrap gap-2" aria-label={t('console.background_agent_jobs.trajectory_integrity')}>
      {metadata.redacted ? (
        <Badge variant="warning">{t('console.background_agent_jobs.integrity_redacted')}</Badge>
      ) : null}
      {metadata.content_truncated ? (
        <Badge variant="warning">
          {metadata.omitted_items
            ? t('console.background_agent_jobs.integrity_omitted', { count: metadata.omitted_items })
            : t('console.background_agent_jobs.integrity_truncated')}
        </Badge>
      ) : null}
    </span>
  )
}

function TurnCard({ turn, lead }: { turn: BackgroundAgentJobTurn; lead: boolean }) {
  const { t } = useTranslation()

  return (
    <li className="relative grid min-w-0 gap-4 border border-border bg-card p-4">
      <span className="absolute top-6 -left-[1.75rem] size-2 rounded-full bg-primary" aria-hidden />
      <header className="grid min-w-0 gap-2">
        <div className="flex min-w-0 flex-wrap items-center gap-x-2 gap-y-1.5">
          <Badge variant="outline">{turn.kind}</Badge>
          <Badge variant={lead ? 'default' : 'secondary'}>
            {t(
              lead ? 'console.background_agent_jobs.turn_scope_lead' : 'console.background_agent_jobs.turn_scope_child'
            )}
          </Badge>
          <TurnStatusBadge status={turn.status} />
          <span className="ml-auto shrink-0 text-xs text-muted-foreground">{formatConsoleDate(turn.started_at)}</span>
        </div>
        <div className="flex min-w-0 flex-wrap items-center gap-x-3 gap-y-1 text-xs text-muted-foreground">
          <span className="break-all font-mono">{turn.runtime_turn_id}</span>
          <span className="tabular-nums">rev {turn.revision}</span>
          <span className="tabular-nums">
            {t('console.background_agent_jobs.message_count', { count: turn.trajectory.messages.length })}
          </span>
        </div>
      </header>

      <TurnProgress turn={turn} />
      <TurnMessages turn={turn} />
    </li>
  )
}

function TurnStatusBadge({ status }: { status: BackgroundAgentJobTurn['status'] }) {
  const tone = match(status)
    .with('completed', () => 'positive' as const)
    .with('failed', () => 'danger' as const)
    .with('interrupted', () => 'warning' as const)
    .otherwise(() => 'info' as const)
  return <StatusIndicator tone={tone}>{status}</StatusIndicator>
}

/** The runtime counters, plan, and touched files for one Turn. Empty facets stay hidden. */
function TurnProgress({ turn }: { turn: BackgroundAgentJobTurn }) {
  const { t } = useTranslation()
  const { active_item: activeItem, files_changed: files, plan, tools_used: tools } = turn.progress

  return (
    <div className="grid min-w-0 gap-3">
      <dl className="grid grid-cols-1 gap-px border border-border bg-border sm:grid-cols-4">
        <Metric label={t('console.background_agent_jobs.tool_calls')} value={turn.progress.tool_calls} />
        <Metric label={t('console.background_agent_jobs.completed_items')} value={turn.progress.completed_items} />
        <div className="grid content-start gap-1 bg-card px-3 py-2 sm:col-span-2">
          <dt className="text-xs text-muted-foreground">{t('console.background_agent_jobs.active_item')}</dt>
          <dd className="break-all font-mono text-xs leading-5">
            {activeItem ? `${activeItem.name} · ${activeItem.id}` : '—'}
          </dd>
        </div>
      </dl>

      {tools.length > 0 ? (
        <LabeledRow label={t('console.background_agent_jobs.tools_used')}>
          <span className="flex flex-wrap gap-1.5">
            {tools.map(tool => (
              <Badge key={tool.name} variant="secondary" className="font-mono">
                {tool.name} ×{tool.calls}
              </Badge>
            ))}
          </span>
        </LabeledRow>
      ) : null}

      {turn.usage ? (
        <LabeledRow label={t('console.background_agent_jobs.token_usage')}>
          <TokenUsage usage={turn.usage} />
        </LabeledRow>
      ) : null}

      {plan ? (
        <LabeledRow label={t('console.background_agent_jobs.plan')}>
          {plan.explanation ? (
            <p className="mb-1.5 text-xs leading-5 text-muted-foreground">{plan.explanation}</p>
          ) : null}
          <ol className="grid gap-1">
            {plan.steps.map((step, index) => (
              <PlanStep key={`${index}:${step.step}`} step={step} />
            ))}
          </ol>
        </LabeledRow>
      ) : null}

      {files.length > 0 ? (
        <LabeledRow label={t('console.background_agent_jobs.files_changed')}>
          <ul className="grid gap-0.5">
            {files.map(file => (
              <li key={file} className="flex min-w-0 items-center gap-1.5 font-mono text-xs">
                <RiFileTextLine className="size-3.5 shrink-0 text-muted-foreground" aria-hidden />
                <span className="break-all">{file}</span>
              </li>
            ))}
          </ul>
        </LabeledRow>
      ) : null}
    </div>
  )
}

function Metric({ label, value }: { label: string; value: number }) {
  return (
    <div className="grid content-start gap-1 bg-card px-3 py-2">
      <dt className="text-xs text-muted-foreground">{label}</dt>
      <dd className="text-sm tabular-nums">{value.toLocaleString()}</dd>
    </div>
  )
}

function LabeledRow({ label, children }: { label: string; children: ReactNode }) {
  return (
    <div className="grid min-w-0 gap-1.5">
      <span className="text-xs text-muted-foreground">{label}</span>
      <div className="min-w-0">{children}</div>
    </div>
  )
}

function PlanStep({ step }: { step: BackgroundAgentJobTurnPlanStep }) {
  const Icon = match(step.status)
    .with('completed', () => RiCheckboxCircleFill)
    .with('in_progress', () => RiProgress3Line)
    .otherwise(() => RiCheckboxBlankCircleLine)

  return (
    <li className="flex min-w-0 items-start gap-2 text-xs leading-5">
      <Icon
        className={cn(
          'mt-0.5 size-3.5 shrink-0',
          step.status === 'completed' ? 'text-success' : 'text-muted-foreground'
        )}
        aria-hidden
      />
      <span className={cn('break-words', step.status === 'completed' && 'text-muted-foreground line-through')}>
        {step.step}
      </span>
    </li>
  )
}

/** Codex usage accounting, aligned so the thread total and the last call compare at a glance. */
function TokenUsage({ usage }: { usage: NonNullable<BackgroundAgentJobTurn['usage']> }) {
  const rows = [
    { key: 'thread', breakdown: usage.thread_total },
    { key: 'last call', breakdown: usage.last_model_call }
  ]

  return (
    <div className="grid gap-1">
      <table className="w-full border-collapse font-mono text-xs tabular-nums">
        <thead className="text-muted-foreground">
          <tr>
            <th className="py-0.5 text-left font-normal" />
            {TOKEN_COLUMNS.map(column => (
              <th key={column.key} className="py-0.5 pl-3 text-right font-normal">
                {column.key}
              </th>
            ))}
          </tr>
        </thead>
        <tbody>
          {rows.map(row => (
            <tr key={row.key} className="border-t border-border">
              <td className="py-0.5 pr-3 text-muted-foreground">{row.key}</td>
              {TOKEN_COLUMNS.map(column => (
                <td key={column.key} className="py-0.5 pl-3 text-right">
                  {column.read(row.breakdown).toLocaleString()}
                </td>
              ))}
            </tr>
          ))}
        </tbody>
      </table>
      {usage.model_context_window === undefined ? null : (
        <span className="font-mono text-xs text-muted-foreground tabular-nums">
          context {usage.model_context_window.toLocaleString()}
        </span>
      )}
    </div>
  )
}

const TOKEN_COLUMNS: {
  key: string
  read: (breakdown: BackgroundAgentJobTurnUsageBreakdown) => number
}[] = [
  { key: 'total', read: breakdown => breakdown.total_tokens },
  { key: 'input', read: breakdown => breakdown.input_tokens },
  { key: 'cached', read: breakdown => breakdown.cached_input_tokens },
  { key: 'output', read: breakdown => breakdown.output_tokens },
  { key: 'reasoning', read: breakdown => breakdown.reasoning_output_tokens }
]

/**
 * Recorded trajectory of one Turn. Prompt and answer text flows as Markdown so
 * it can be read, while tool traffic collapses into tiles that open to the
 * pretty-printed payload — the whole message no longer arrives as a JSON dump.
 */
function TurnMessages({ turn }: { turn: BackgroundAgentJobTurn }) {
  if (turn.trajectory.messages.length === 0) return null

  return (
    <div className="grid min-w-0 gap-3 border-t border-border pt-4">
      {turn.trajectory.messages.map((message, index) => (
        <TrajectoryMessageView key={`${turn.id}:${index}`} message={message} />
      ))}
    </div>
  )
}

function TrajectoryMessageView({ message }: { message: TrajectoryMessage }) {
  const text = messageText(message)

  if (message.role === 'tool') {
    return (
      <ToolTile icon={RiTerminalBoxLine} name={message.name} reference={message.tool_call_id}>
        <CodeBlock>{prettyJSON(truncate(text, 16_000))}</CodeBlock>
      </ToolTile>
    )
  }

  if (message.role === 'assistant') {
    const calls = message.tool_calls ?? []
    return (
      <article className="grid min-w-0 gap-2">
        {text ? (
          <div className="grid min-w-0 gap-1.5">
            <MessageRole role="assistant" icon={RiRobot2Line} />
            <MarkdownBody text={text} />
          </div>
        ) : null}
        {calls.map(call => (
          <ToolTile key={call.id} icon={RiCodeSSlashLine} name={call.function.name} reference={call.id}>
            <CodeBlock>{prettyJSON(truncate(call.function.arguments, 16_000))}</CodeBlock>
          </ToolTile>
        ))}
      </article>
    )
  }

  // `developer` carries the system instruction and `user` the queued prompt.
  // Both are long-form input, so they read as a bordered quote rather than a bubble.
  return (
    <article className="grid min-w-0 gap-1.5 border-l-2 border-border pl-3">
      <MessageRole role={message.role} icon={RiUser3Line} />
      {text ? <MarkdownBody text={text} /> : <CodeBlock>{formatJSON(message.content)}</CodeBlock>}
    </article>
  )
}

function MessageRole({ role, icon: Icon }: { role: string; icon: typeof RiUser3Line }) {
  return (
    <span className="flex items-center gap-1.5 text-xs text-muted-foreground">
      <Icon className="size-3.5" aria-hidden />
      <span className="font-medium">{role}</span>
    </span>
  )
}

/** Collapsed one-line summary of tool traffic; the payload is one click away. */
function ToolTile({
  icon: Icon,
  name,
  reference,
  children
}: {
  icon: typeof RiTerminalBoxLine
  name: string
  reference: string
  children: ReactNode
}) {
  return (
    <Accordion className="min-w-0 border border-border bg-card">
      <AccordionItem value="payload">
        <AccordionTrigger className="items-center gap-2 px-3 py-2 text-xs font-normal hover:no-underline">
          <span className="flex min-w-0 flex-1 items-center gap-2">
            <Icon className="size-3.5 shrink-0 text-muted-foreground" aria-hidden />
            <span className="truncate font-mono font-medium">{name}</span>
            <span className="ml-auto truncate font-mono text-muted-foreground">{reference}</span>
          </span>
        </AccordionTrigger>
        <AccordionContent className="border-t border-border px-3 py-2">{children}</AccordionContent>
      </AccordionItem>
    </Accordion>
  )
}

/** Monospace payload surface matching the conversations detail page. */
function CodeBlock({ children }: { children: string }) {
  return (
    <pre className="max-h-80 overflow-auto border border-border bg-muted px-3 py-2 font-mono text-xs leading-5 whitespace-pre">
      {children}
    </pre>
  )
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
        attempt === currentAttempt && attemptTurns.some(turn => turn.runtime_thread_id === currentLeadThreadID)
          ? currentLeadThreadID
          : attemptTurns[0]?.runtime_thread_id
    }))
}

function cancellable(status: JobStatus): boolean {
  return status === 'queued' || status === 'running' || status === 'waiting_on_user'
}

/** Whether a card's status says more than the column it sits in already did. */
function distinguishesStatus(status: JobStatus): boolean {
  const column = columns.find(candidate => candidate.statuses.includes(status))
  return (column?.statuses.length ?? 0) > 1
}

function formatDuration(seconds: number): string {
  if (seconds < 60) return `${seconds}s`
  if (seconds < 3_600) return `${Math.floor(seconds / 60)}m`
  if (seconds < 86_400) return `${Math.floor(seconds / 3_600)}h ${Math.floor((seconds % 3_600) / 60)}m`
  return `${Math.floor(seconds / 86_400)}d ${Math.floor((seconds % 86_400) / 3_600)}h`
}

/** Preferred human-readable field of a freeform result/error object, when it has one. */
function outcomeText(value: Record<string, unknown>): string {
  for (const key of ['summary', 'output_text', 'message', 'reason', 'code']) {
    if (typeof value[key] === 'string' && value[key]) return String(value[key])
  }
  return ''
}

/** Flattens `ankole_chatml` content — a plain string, or the text parts of a multipart prompt. */
function messageText(message: TrajectoryMessage): string {
  const { content } = message
  if (typeof content === 'string') return content
  if (!Array.isArray(content)) return ''
  return content
    .map(part => (typeof part.text === 'string' ? part.text : formatJSON(part)))
    .join('\n')
    .trim()
}

/** Re-indents JSON payloads; passes non-JSON text through unchanged. */
function prettyJSON(text: string): string {
  const trimmed = text.trim()
  if (!trimmed.startsWith('{') && !trimmed.startsWith('[')) return text
  try {
    return formatJSON(JSON.parse(trimmed))
  } catch {
    return text
  }
}

function truncate(value: string, limit: number): string {
  return value.length <= limit ? value : `${value.slice(0, limit)}…`
}
