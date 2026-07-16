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
  ankoleWebSubagentDelegationControllerCancelMutation,
  ankoleWebSubagentDelegationControllerIndexOptions,
  ankoleWebSubagentDelegationControllerShowOptions
} from '../api/generated/@tanstack/react-query.gen'
import type { SubagentDelegationItem } from '../api/generated/types.gen'
import { ErrorBlock, formatConsoleDate } from '../console-primitives'
import { PageHeader, ResourceSearch, StatusIndicator } from '../console-shell'

type Column = {
  key: 'todo' | 'active' | 'finished'
  statuses: SubagentDelegationItem['status'][]
}

type DelegationTurn = NonNullable<SubagentDelegationItem['turns']>[number]

const columns: Column[] = [
  { key: 'todo', statuses: ['queued'] },
  { key: 'active', statuses: ['running', 'waiting_on_user'] },
  { key: 'finished', statuses: ['succeeded', 'failed', 'stopped'] }
]

export function DelegationsPage() {
  const { t } = useTranslation()
  const queryClient = useQueryClient()
  const [searchParams, setSearchParams] = useSearchParams()
  const agentFilter = searchParams.get('agent') ?? ''
  const selectedID = searchParams.get('delegation') ?? undefined
  const [cancelTargetID, setCancelTargetID] = useState<string>()
  const list = useQuery({
    ...ankoleWebSubagentDelegationControllerIndexOptions({
      query: { agent: agentFilter.trim() || undefined, limit: 100 }
    }),
    refetchInterval: 5_000
  })
  const detail = useQuery({
    ...ankoleWebSubagentDelegationControllerShowOptions({
      path: { delegation_id: selectedID ?? 'not-selected' }
    }),
    enabled: Boolean(selectedID),
    refetchInterval: selectedID ? 5_000 : false,
    retry: false
  })
  const cancel = useMutation({
    ...ankoleWebSubagentDelegationControllerCancelMutation(),
    onSuccess: () => {
      toast.success(t('console.delegations.cancelled'))
      setCancelTargetID(undefined)
      void queryClient.invalidateQueries()
    },
    onError: error => toast.error(requestErrorMessage(error))
  })
  const delegations = list.data?.delegations ?? []
  const calibration = list.data?.calibration_summary
  const selected = detail.data?.delegation
  const cancelTarget =
    delegations.find(delegation => delegation.id === cancelTargetID) ??
    (selected?.id === cancelTargetID ? selected : undefined)

  const setAgentFilter = (value: string) => {
    const next = new URLSearchParams(searchParams)
    if (value) next.set('agent', value)
    else next.delete('agent')
    setSearchParams(next, { replace: true })
  }

  const openDelegation = (id: string) => {
    const next = new URLSearchParams(searchParams)
    next.set('delegation', id)
    setSearchParams(next)
  }

  const closeDelegation = () => {
    const next = new URLSearchParams(searchParams)
    next.delete('delegation')
    setSearchParams(next, { replace: true })
  }

  const grouped = useMemo(
    () =>
      Object.fromEntries(
        columns.map(column => [
          column.key,
          delegations.filter(delegation => column.statuses.includes(delegation.status))
        ])
      ) as Record<Column['key'], SubagentDelegationItem[]>,
    [delegations]
  )

  return (
    <div className="grid gap-6">
      <PageHeader title={t('console.delegations.title')} description={t('console.delegations.description')} />
      <ResourceSearch
        label={t('console.delegations.agent_filter')}
        placeholder={t('console.delegations.agent_filter')}
        value={agentFilter}
        onChange={setAgentFilter}
      />

      {calibration && calibration.forecast_count > 0 ? (
        <section className="grid gap-3 border border-border bg-card p-4">
          <h2 className="font-medium">{t('console.delegations.calibration_overview')}</h2>
          <dl className="grid gap-3 text-sm sm:grid-cols-2 xl:grid-cols-5">
            <Metric label={t('console.delegations.forecast_count')} value={String(calibration.forecast_count)} />
            <Metric
              label={t('console.delegations.resolved_forecast_count')}
              value={String(calibration.resolved_forecast_count)}
            />
            <Metric
              label={t('console.delegations.mean_brier_score')}
              value={formatMetric(calibration.mean_brier_score)}
            />
            <Metric label={t('console.delegations.no_edge_rate')} value={formatPercent(calibration.no_edge_rate)} />
            <Metric
              label={t('console.delegations.confidence_hit_rate')}
              value={
                calibration.confidence_buckets.length
                  ? calibration.confidence_buckets
                      .map(
                        bucket =>
                          `C${bucket.confidence}: ${formatPercent(bucket.hit_rate)} (${bucket.hits}/${bucket.forecasts})`
                      )
                      .join('\n')
                  : '—'
              }
            />
          </dl>
        </section>
      ) : null}

      {list.error ? (
        <ErrorBlock error={list.error} />
      ) : !list.isLoading && delegations.length === 0 ? (
        <Empty className="items-start border border-border bg-card text-left">
          <EmptyHeader className="items-start">
            <EmptyMedia variant="icon">
              <RiTimeLine aria-hidden />
            </EmptyMedia>
            <EmptyTitle>
              {agentFilter ? t('console.empty.no_results_title') : t('console.delegations.empty_title')}
            </EmptyTitle>
            <EmptyDescription>
              {agentFilter ? t('console.empty.no_results_description') : t('console.delegations.empty_description')}
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
                <h3 className="font-medium">{t(`console.delegations.column_${column.key}`)}</h3>
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
                    {t('console.delegations.empty_column')}
                  </p>
                ) : (
                  grouped[column.key].map(task => (
                    <DelegationCard
                      key={task.id}
                      task={task}
                      cancelling={cancel.isPending}
                      onCancel={() => setCancelTargetID(task.id)}
                      onOpen={() => openDelegation(task.id)}
                    />
                  ))
                )}
              </div>
            </section>
          ))}
        </div>
      )}

      <Sheet open={Boolean(selectedID)} onOpenChange={open => !open && closeDelegation()}>
        <SheetContent className="w-full sm:max-w-2xl">
          <SheetHeader>
            <SheetTitle>{selected?.title ?? t('console.delegations.detail_title')}</SheetTitle>
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
                    label={t('console.delegations.status')}
                    value={<StatusBadge status={selected.status} />}
                  />
                  <DetailField label={t('console.delegations.runtime')} value={selected.runtime} />
                  {selected.runtime === 'deep_research' ? (
                    <DetailField label={t('console.delegations.mode')} value={selected.mode ?? 'general'} />
                  ) : null}
                  <DetailField label={t('console.delegations.codex_account')} value={selected.codex_account_id} />
                  <DetailField label={t('console.delegations.attempts')} value={String(selected.attempts)} />
                  <DetailField
                    label={t('console.delegations.duration')}
                    value={formatDuration(selected.duration_seconds)}
                  />
                  <DetailField label={t('console.delegations.workdir')} value={selected.workdir ?? '—'} wide />
                  <DetailField label={t('console.delegations.task')} value={selected.task ?? '—'} wide />
                  <DetailField label={t('console.delegations.background')} value={selected.background ?? '—'} wide />
                  <DetailField label={t('console.delegations.notes')} value={selected.notes ?? '—'} wide />
                  {selected.runtime === 'deep_research' ? (
                    <>
                      <DetailField
                        label={t('console.delegations.research_progress')}
                        value={researchProgress(selected)}
                        wide
                      />
                      <DetailField
                        label={t('console.delegations.evidence_stats')}
                        value={evidenceStatsSummary(selected.result.evidence_stats)}
                        wide
                      />
                      <DetailField
                        label={t('console.delegations.stop_reason')}
                        value={typeof selected.result.stop_reason === 'string' ? selected.result.stop_reason : '—'}
                      />
                      {selected.mode === 'retrospect' ? (
                        <>
                          <DetailField
                            label={t('console.delegations.source_delegation')}
                            value={selected.source_delegation_id ?? '—'}
                            wide
                          />
                          <DetailField
                            label={t('console.delegations.actual_outcome')}
                            value={
                              typeof selected.actual_outcome === 'boolean'
                                ? String(selected.actual_outcome)
                                : t('console.delegations.outcome_resolved_by_research')
                            }
                          />
                        </>
                      ) : null}
                      <DetailField
                        label={t('console.delegations.verification')}
                        value={verificationSummary(selected.result.verification)}
                        wide
                      />
                      <DetailField
                        label={t('console.delegations.calibration')}
                        value={calibrationSummary(selected.result.calibration)}
                        wide
                      />
                    </>
                  ) : null}
                  <DetailField
                    label={t('console.delegations.trajectory_integrity')}
                    value={turnsSummary(selected.turns)}
                    wide
                  />
                  <DetailField
                    label={t('console.delegations.result')}
                    value={summary(selected.status === 'failed' ? selected.error : selected.result)}
                    wide
                  />
                </dl>

                <section className="grid gap-3">
                  <h3 className="font-medium">{t('console.delegations.timeline')}</h3>
                  {selected.turns?.length ? (
                    <div className="grid gap-5">
                      {groupTurnsByAttempt(selected.turns, selected.attempts, selected.runtime_thread_id).map(group => (
                        <section key={group.attempt} className="grid gap-2">
                          <h4 className="text-xs font-medium text-muted-foreground">
                            {t('console.delegations.attempt_label', { count: group.attempt })}
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
                                        ? 'console.delegations.turn_scope_lead'
                                        : 'console.delegations.turn_scope_child'
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
                    <p className="text-sm text-muted-foreground">{t('console.delegations.no_turns')}</p>
                  )}
                </section>
              </>
            )}
          </div>

          {selected && cancellable(selected.status) ? (
            <SheetFooter>
              <Button variant="destructive" disabled={cancel.isPending} onClick={() => setCancelTargetID(selected.id)}>
                <RiCloseCircleLine />
                {t('console.delegations.cancel')}
              </Button>
            </SheetFooter>
          ) : null}
        </SheetContent>
      </Sheet>

      <Dialog open={Boolean(cancelTarget)} onOpenChange={open => !open && setCancelTargetID(undefined)}>
        <DialogContent>
          <DialogHeader>
            <DialogTitle>{t('console.delegations.cancel_title')}</DialogTitle>
            <DialogDescription>
              {t('console.delegations.cancel_confirm', {
                title: cancelTarget?.title ?? cancelTarget?.id ?? ''
              })}
            </DialogDescription>
          </DialogHeader>
          <DialogFooter>
            <DialogClose render={<Button variant="outline" />}>{t('common.cancel')}</DialogClose>
            <Button
              variant="destructive"
              disabled={!cancelTarget || cancel.isPending}
              onClick={() => cancelTarget && cancel.mutate({ path: { delegation_id: cancelTarget.id } })}>
              {t('console.delegations.cancel')}
            </Button>
          </DialogFooter>
        </DialogContent>
      </Dialog>
    </div>
  )
}

function DelegationCard({
  task,
  cancelling,
  onCancel,
  onOpen
}: {
  task: SubagentDelegationItem
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
        aria-label={t('console.delegations.open_detail', { title: task.title ?? task.id })}
        onClick={onOpen}>
        <div className="flex items-start justify-between gap-3">
          <h4 className="line-clamp-2 font-medium leading-5">{task.title ?? task.id}</h4>
          <StatusBadge status={task.status} />
        </div>
        <div className="grid gap-1 text-xs text-muted-foreground">
          <span className="truncate font-mono">{task.agent_uid}</span>
          <span className="flex items-center gap-1.5">
            <RiTimeLine className="size-3.5" />
            {formatDuration(task.duration_seconds)} · {t('console.delegations.attempt_count', { count: task.attempts })}
          </span>
          <span>{task.mode ? `${task.runtime} · ${task.mode}` : task.runtime}</span>
          {task.runtime === 'deep_research' ? <span>{compactResearchStats(task.result)}</span> : null}
        </div>
      </button>
      {cancellable(task.status) ? (
        <Button size="xs" variant="outline" disabled={cancelling} onClick={onCancel}>
          {t('console.delegations.cancel')}
        </Button>
      ) : null}
    </article>
  )
}

function StatusBadge({ status }: { status: SubagentDelegationItem['status'] }) {
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
  return <StatusIndicator tone={tone}>{t(`console.delegations.status_${status}`)}</StatusIndicator>
}

function DetailField({ label, value, wide = false }: { label: string; value: ReactNode; wide?: boolean }) {
  return (
    <div className={wide ? 'col-span-2 grid gap-1' : 'grid gap-1'}>
      <dt className="text-xs text-muted-foreground">{label}</dt>
      <dd className="whitespace-pre-wrap break-words">{value}</dd>
    </div>
  )
}

function Metric({ label, value }: { label: string; value: ReactNode }) {
  return (
    <div className="grid gap-1 border-l-2 border-border pl-3">
      <dt className="text-xs text-muted-foreground">{label}</dt>
      <dd className="whitespace-pre-wrap font-medium">{value}</dd>
    </div>
  )
}

function TurnRuntimeSnapshot({ turn }: { turn: DelegationTurn }) {
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
      <SnapshotField label={t('console.delegations.completed_items')} value={String(turn.progress.completed_items)} />
      <SnapshotField label={t('console.delegations.tool_calls')} value={String(turn.progress.tool_calls)} />
      <SnapshotField label={t('console.delegations.tools_used')} value={tools} />
      <SnapshotField label={t('console.delegations.token_usage')} value={tokenUsageSummary(turn.usage)} />
      <SnapshotField
        label={t('console.delegations.active_item')}
        value={turn.progress.active_item ? `${turn.progress.active_item.name} (${turn.progress.active_item.id})` : '—'}
      />
      <SnapshotField label={t('console.delegations.plan')} value={planText} />
      <SnapshotField label={t('console.delegations.files_changed')} value={files} wide />
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

function tokenUsageSummary(usage: DelegationTurn['usage']): string {
  if (!usage) return '—'
  const total = usage.thread_total
  const last = usage.last_model_call
  const context = usage.model_context_window === undefined ? '' : ` · context=${usage.model_context_window}`
  return [
    `thread: total=${total.total_tokens} · input=${total.input_tokens} · cached=${total.cached_input_tokens} · output=${total.output_tokens} · reasoning=${total.reasoning_output_tokens}${context}`,
    `last call: total=${last.total_tokens} · input=${last.input_tokens} · cached=${last.cached_input_tokens} · output=${last.output_tokens} · reasoning=${last.reasoning_output_tokens}`
  ].join('\n')
}

function groupTurnsByAttempt(turns: DelegationTurn[], currentAttempt: number, currentLeadThreadID?: string | null) {
  const groups = new Map<number, DelegationTurn[]>()
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

function cancellable(status: SubagentDelegationItem['status']): boolean {
  return status === 'queued' || status === 'running' || status === 'waiting_on_user'
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

function researchProgress(delegation: SubagentDelegationItem): string {
  const latestTurn = delegation.turns?.at(-1)
  const state = delegation.status === 'running' ? (latestTurn?.status ?? 'starting') : delegation.status
  return [`state=${state}`, latestTurn ? `turn=${latestTurn.runtime_turn_id}` : undefined]
    .filter((item): item is string => Boolean(item))
    .join('\n')
}

function evidenceStatsSummary(value: unknown): string {
  const stats = objectValue(value)
  if (!Object.keys(stats).length) return '—'
  return [
    numberLine('archived_sources', stats.archived_sources),
    numberLine('independent_sources', stats.independent_sources),
    numberLine('notes', stats.notes),
    numberLine('citations', stats.citations),
    numberLine('unresolved_conflicts', stats.unresolved_conflicts)
  ]
    .filter((item): item is string => Boolean(item))
    .join('\n')
}

function verificationSummary(value: unknown): string {
  const verification = objectValue(value)
  if (!Object.keys(verification).length) return '—'
  return typeof verification.status === 'string' ? `status=${verification.status}` : '—'
}

function calibrationSummary(value: unknown): string {
  const calibration = objectValue(value)
  return typeof calibration.brier_score === 'number' ? `brier_score=${calibration.brier_score.toFixed(6)}` : '—'
}

function compactResearchStats(result: Record<string, unknown>): string {
  const stats = objectValue(result.evidence_stats)
  const stopReason = typeof result.stop_reason === 'string' ? result.stop_reason : undefined
  const archived = typeof stats.archived_sources === 'number' ? `${stats.archived_sources} sources` : undefined
  const independent =
    typeof stats.independent_sources === 'number' ? `${stats.independent_sources} independent` : undefined
  return [stopReason, archived, independent].filter(Boolean).join(' · ') || 'research artifacts pending'
}

function objectValue(value: unknown): Record<string, unknown> {
  return value && typeof value === 'object' && !Array.isArray(value) ? (value as Record<string, unknown>) : {}
}

function numberLine(label: string, value: unknown): string | undefined {
  return typeof value === 'number' ? `${label}=${value}` : undefined
}

function formatMetric(value: number | null): string {
  return value === null ? '—' : value.toFixed(4)
}

function formatPercent(value: number | null): string {
  return value === null ? '—' : `${(value * 100).toFixed(1)}%`
}

function turnsSummary(turns: SubagentDelegationItem['turns']): string {
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
