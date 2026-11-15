import {
  Badge,
  Board,
  BoardCard,
  BoardCardActions,
  BoardCardAside,
  BoardCardDescription,
  BoardCardFooter,
  BoardCardHeader,
  BoardCardProgress,
  BoardCardTitle,
  BoardColumn,
  BoardColumnEmpty,
  BoardColumnHeader,
  Button,
  toast,
  type BoardCardTone,
  type BoardProgressTone,
  type BoardTone
} from '@ankole/uikit'
import {
  AddRegular,
  ArrowRightRegular,
  BotRegular,
  BranchRegular,
  CalendarClockRegular,
  CheckmarkCircleFilled,
  CircleHalfFillRegular,
  ClockRegular,
  FilterRegular,
  FlashRegular,
  PauseCircleRegular,
  SparkleRegular,
  StopFilled
} from '@ankole/uikit/icons'
import { useMutation, useQueryClient } from '@tanstack/react-query'
import type { TFunction } from 'i18next'
import { useMemo, type ReactNode } from 'react'
import { useTranslation } from 'react-i18next'
import { formatRelativeTime } from '../common/date-time'
import { requestErrorMessage } from '../common/request-errors'
import { stopPodJobExecution } from './api/generated/sdk.gen'
import { ChatAvatar } from './chat/chat-avatar'
import { ExecutionStatusMark, isLiveExecutionStatus } from './chat/execution-status'
import type { JobStarterPreset } from './job-create-dialog'
import { jobColumns, jobsError, jobsKeys, type JobBoardItem, type JobCandidateAgent, type JobColumn } from './jobs-api'
import type { PanelInputEvent } from './panel-motion'

function columnMeta(column: JobColumn, hasAttention = false): { icon: ReactNode; tone: BoardTone } {
  switch (column) {
    case 'scheduled':
      return { icon: <ClockRegular />, tone: 'gray' }
    case 'running':
      return { icon: <CircleHalfFillRegular />, tone: hasAttention ? 'amber' : 'blue' }
    case 'completed':
      return { icon: <CheckmarkCircleFilled />, tone: 'green' }
  }
}

function jobKindIcon(kind: JobBoardItem['kind']): ReactNode {
  switch (kind) {
    case 'background_agent_job':
      return <BotRegular aria-hidden className="size-3.5 shrink-0 text-fg-tertiary" />
    case 'workflow':
      return <BranchRegular aria-hidden className="size-3.5 shrink-0 text-fg-tertiary" />
    case 'cron':
      return <CalendarClockRegular aria-hidden className="size-3.5 shrink-0 text-fg-tertiary" />
    case 'automation_job':
      return <FlashRegular aria-hidden className="size-3.5 shrink-0 text-fg-tertiary" />
    case 'checkback':
      return <ClockRegular aria-hidden className="size-3.5 shrink-0 text-fg-tertiary" />
  }
}

export function StatusColumnsBoard({
  items,
  agents,
  agentAvatarByUID,
  selectedID,
  onSelect,
  onQuickCreate
}: {
  items: JobBoardItem[]
  agents: JobCandidateAgent[]
  agentAvatarByUID: Map<string, string | null | undefined>
  selectedID?: string
  onSelect: (id: string, event?: PanelInputEvent, source?: HTMLElement | null) => void
  onQuickCreate: (preset: JobStarterPreset) => void
}) {
  const { t } = useTranslation()
  const canCreateScheduled = agents.length > 0
  const canCreateOneOff = agents.some(agent => agent.canRunBackgroundJob)

  return (
    <Board className="flex-1">
      {jobColumns.map(column => {
        const cards = items
          .filter(item => item.column === column)
          .sort((a, b) => {
            if (column === 'running' && a.attention !== b.attention) {
              return a.attention ? -1 : 1
            }
            return 0
          })
        const meta = columnMeta(column, column === 'running' && cards.some(card => card.attention))

        const quickAction =
          column === 'scheduled' && canCreateScheduled ? (
            <Button
              type="button"
              variant="ghost"
              size="icon-xs"
              aria-label={t('pod.jobs.quick_add_cron')}
              title={t('pod.jobs.quick_add_cron')}
              onClick={() => onQuickCreate({ mode: 'cron' })}>
              <AddRegular aria-hidden />
            </Button>
          ) : column === 'running' && canCreateOneOff ? (
            <Button
              type="button"
              variant="ghost"
              size="icon-xs"
              aria-label={t('pod.jobs.new_job')}
              title={t('pod.jobs.new_job')}
              onClick={() => onQuickCreate({ mode: 'one_off' })}>
              <AddRegular aria-hidden />
            </Button>
          ) : undefined

        return (
          <BoardColumn key={column} aria-label={t(`pod.jobs.columns.${column}`)}>
            <BoardColumnHeader icon={meta.icon} tone={meta.tone} count={cards.length} actions={quickAction}>
              {t(`pod.jobs.columns.${column}`)}
            </BoardColumnHeader>
            {cards.length > 0 ? (
              cards.map(card => (
                <JobCard
                  key={card.id}
                  item={card}
                  viewMode="status"
                  agentAvatarURL={card.agentUID ? agentAvatarByUID.get(card.agentUID) : undefined}
                  selected={selectedID === card.id}
                  onSelect={(event, button) => onSelect(card.id, event, button)}
                />
              ))
            ) : (
              <BoardColumnEmpty>{t(`pod.jobs.column_empty_${column}`)}</BoardColumnEmpty>
            )}
          </BoardColumn>
        )
      })}
    </Board>
  )
}

export function AgentColumnsBoard({
  items,
  agents,
  selectedID,
  onSelect,
  onQuickCreate
}: {
  items: JobBoardItem[]
  agents: JobCandidateAgent[]
  selectedID?: string
  onSelect: (id: string, event?: PanelInputEvent, source?: HTMLElement | null) => void
  onQuickCreate: (preset: JobStarterPreset) => void
}) {
  const { t } = useTranslation()

  const columns = useMemo(() => {
    const orderRank = (item: JobBoardItem) => {
      if (item.attention) return 0
      if (item.column === 'running') return 1
      if (item.column === 'scheduled') return 2
      return 3
    }

    const byAgent = new Map<
      string,
      { key: string; title: string; avatarURL?: string | null; canCreate: boolean; cards: JobBoardItem[] }
    >()
    for (const agent of agents) {
      byAgent.set(agent.uid, {
        key: agent.uid,
        title: agent.displayName,
        avatarURL: agent.avatarURL,
        canCreate: true,
        cards: []
      })
    }

    const automationCards: JobBoardItem[] = []
    for (const item of items) {
      if (!item.agentUID) {
        automationCards.push(item)
        continue
      }
      let bucket = byAgent.get(item.agentUID)
      if (!bucket) {
        bucket = {
          key: item.agentUID,
          title: item.agentName || `@${item.agentUID}`,
          canCreate: false,
          cards: []
        }
        byAgent.set(item.agentUID, bucket)
      }
      bucket.cards.push(item)
    }

    const result = [...byAgent.values()]
      .filter(bucket => bucket.cards.length > 0 || agents.length <= 4)
      .map(bucket => ({
        ...bucket,
        cards: [...bucket.cards].sort((a, b) => orderRank(a) - orderRank(b))
      }))

    if (automationCards.length > 0) {
      result.push({
        key: '__automations__',
        title: t('pod.jobs.page_automations'),
        canCreate: false,
        cards: [...automationCards].sort((a, b) => orderRank(a) - orderRank(b))
      })
    }
    return result
  }, [agents, items, t])

  return (
    <Board className="flex-1">
      {columns.map(column => {
        const hasAttention = column.cards.some(card => card.attention)
        const hasRunning = column.cards.some(card => card.column === 'running')
        const tone: BoardTone = hasAttention ? 'amber' : hasRunning ? 'blue' : 'gray'

        return (
          <BoardColumn key={column.key} aria-label={column.title}>
            <BoardColumnHeader
              icon={
                column.key === '__automations__' ? (
                  <FlashRegular />
                ) : (
                  <ChatAvatar name={column.title} src={column.avatarURL} agent round size="xs" />
                )
              }
              tone={tone}
              count={column.cards.length}
              actions={
                column.canCreate ? (
                  <Button
                    type="button"
                    variant="ghost"
                    size="icon-xs"
                    aria-label={t('pod.jobs.quick_add_agent', { name: column.title })}
                    title={t('pod.jobs.quick_add_agent', { name: column.title })}
                    onClick={() => onQuickCreate({ mode: 'one_off', agentUID: column.key })}>
                    <AddRegular aria-hidden />
                  </Button>
                ) : undefined
              }>
              {column.title}
            </BoardColumnHeader>
            {column.cards.length > 0 ? (
              column.cards.map(card => (
                <JobCard
                  key={card.id}
                  item={card}
                  viewMode="agent"
                  agentAvatarURL={column.avatarURL}
                  selected={selectedID === card.id}
                  onSelect={(event, button) => onSelect(card.id, event, button)}
                />
              ))
            ) : (
              <BoardColumnEmpty>{t('pod.jobs.column_empty_agent')}</BoardColumnEmpty>
            )}
          </BoardColumn>
        )
      })}
    </Board>
  )
}

function JobCard({
  item,
  viewMode,
  agentAvatarURL,
  selected,
  onSelect
}: {
  item: JobBoardItem
  viewMode: 'status' | 'agent'
  agentAvatarURL?: string | null
  selected: boolean
  onSelect: (event: PanelInputEvent, source: HTMLButtonElement) => void
}) {
  const { t, i18n } = useTranslation()
  const client = useQueryClient()

  const stopMutation = useMutation({
    mutationFn: () => {
      if (!item.activeExecutionKind || !item.activeExecutionID) {
        throw new Error('Missing active execution')
      }
      return stopPodJobExecution({
        path: {
          kind: item.activeExecutionKind,
          run_id: Number(item.activeExecutionID)
        }
      })
    },
    onSuccess: () => {
      void client.invalidateQueries({ queryKey: jobsKeys.all })
    },
    onError: error => {
      toast.error(requestErrorMessage(jobsError(error)))
    }
  })

  const hasPlan = item.planTotal != null && item.planTotal > 0
  const metaDetail = hasPlan ? null : cardProgressSummary(item, t)
  const planLabel = hasPlan
    ? `${item.planCompleted ?? 0}/${item.planTotal}${item.chainLength > 1 ? ` · +${item.chainLength - 1}` : ''}`
    : null
  const snippet = item.summary?.trim()
  const showSnippet = Boolean(snippet && snippet !== item.title.trim())

  const timestamp =
    item.column === 'scheduled' && item.nextRunAt
      ? formatRelativeTime(item.nextRunAt, i18n.language)
      : formatRelativeTime(item.updatedAt, i18n.language)

  const cardTone: BoardCardTone = item.attention
    ? item.status === 'waiting_on_user'
      ? 'warning'
      : 'danger'
    : 'default'

  return (
    <BoardCard selected={selected} tone={cardTone} className={item.status === 'paused' ? 'opacity-80' : undefined}>
      <BoardCardHeader>
        {jobKindIcon(item.kind)}
        <span className="truncate font-medium text-fg-secondary">{t(`pod.jobs.kinds.${item.kind}`)}</span>

        {item.cardType === 'routine' && item.status === 'paused' ? (
          <Badge variant="secondary" size="sm">
            {t('pod.jobs.status_paused')}
          </Badge>
        ) : item.cardType === 'routine' && item.triggerSummary ? (
          <span className="max-w-36 truncate rounded-mini bg-background-secondary px-1.5 py-0.5 font-mono text-[11px] leading-3.5 text-fg-secondary">
            {item.triggerSummary}
          </span>
        ) : metaDetail ? (
          <span className="truncate font-mono text-[11px] text-fg-tertiary tabular-nums">{metaDetail}</span>
        ) : null}

        {item.attention && (
          <Badge variant={item.status === 'waiting_on_user' ? 'warning' : 'destructive'} size="sm">
            {attentionLabel(item, t)}
          </Badge>
        )}

        <BoardCardAside>
          {item.status === 'paused' ? (
            <PauseCircleRegular aria-hidden className="size-3.5 text-fg-tertiary" />
          ) : isLiveExecutionStatus(item.status) || item.attention ? (
            <span className="flex shrink-0 [&>svg]:size-3.5">
              <ExecutionStatusMark status={item.status} />
            </span>
          ) : item.column === 'completed' ? (
            <CheckmarkCircleFilled aria-hidden className="size-3.5 text-success" />
          ) : null}
          {item.stoppable && item.activeExecutionKind && item.activeExecutionID && (
            <BoardCardActions>
              <Button
                type="button"
                size="icon-xs"
                variant="ghost"
                disabled={stopMutation.isPending}
                aria-label={t('pod.chat_timeline.execution_stop_action')}
                title={t('pod.chat_timeline.execution_stop_action')}
                onClick={() => stopMutation.mutate()}>
                <StopFilled aria-hidden />
              </Button>
            </BoardCardActions>
          )}
        </BoardCardAside>
      </BoardCardHeader>

      <BoardCardTitle
        render={<button type="button" onClick={event => onSelect(event.nativeEvent, event.currentTarget)} />}>
        {item.title}
      </BoardCardTitle>

      {showSnippet && <BoardCardDescription>{snippet}</BoardCardDescription>}

      {hasPlan && item.planTotal != null && (
        <BoardCardProgress
          value={item.planCompleted ?? 0}
          max={item.planTotal}
          tone={cardProgressTone(item)}
          label={planLabel}
        />
      )}

      <BoardCardFooter>
        {viewMode === 'agent' ? (
          <>
            <span
              aria-hidden
              className={
                item.attention
                  ? 'size-1.5 shrink-0 rounded-full bg-warning'
                  : item.column === 'running'
                    ? 'size-1.5 shrink-0 rounded-full bg-info'
                    : item.column === 'completed'
                      ? 'size-1.5 shrink-0 rounded-full bg-success'
                      : 'size-1.5 shrink-0 rounded-full bg-fg-quaternary'
              }
            />
            <span className="min-w-0 truncate">
              {item.conversationTitle || item.pageTitle || t(`pod.jobs.columns.${item.column}`)}
            </span>
          </>
        ) : item.agentUID ? (
          <>
            <ChatAvatar name={item.agentName || `@${item.agentUID}`} src={agentAvatarURL} agent round size="xs" />
            <span className="min-w-0 truncate">{item.agentName || `@${item.agentUID}`}</span>
          </>
        ) : item.pageTitle ? (
          <>
            <FlashRegular aria-hidden className="size-3.5 shrink-0 text-fg-tertiary" />
            <span className="min-w-0 truncate">{item.pageTitle}</span>
          </>
        ) : null}

        {timestamp && <BoardCardAside>{timestamp}</BoardCardAside>}
      </BoardCardFooter>
    </BoardCard>
  )
}

function cardProgressTone(item: JobBoardItem): BoardProgressTone {
  if (item.attention) return item.status === 'waiting_on_user' ? 'warning' : 'danger'
  if (item.column === 'completed') return 'success'
  return 'info'
}

function cardProgressSummary(item: JobBoardItem, t: TFunction): string | null {
  if (item.cardType === 'routine') {
    if (item.status === 'paused') return t('pod.jobs.status_paused')
    return item.triggerSummary ?? null
  }
  const parts: string[] = []
  if (item.planTotal != null && item.planTotal > 0) {
    parts.push(`${item.planCompleted ?? 0}/${item.planTotal}`)
  } else if (item.stepCount > 0) {
    parts.push(t('pod.jobs.step_count', { count: item.stepCount }))
  }
  if (item.chainLength > 1) {
    parts.push(`+${item.chainLength - 1}`)
  }
  return parts.length > 0 ? parts.join(' · ') : null
}

function attentionLabel(item: JobBoardItem, t: (key: string) => string): string {
  if (item.status === 'waiting_on_user') return t('pod.jobs.attention_waiting')
  if (item.status === 'unavailable') return t('pod.jobs.status_unavailable')
  return t('pod.jobs.attention_failed')
}

export function FilteredEmptyJobsState({ onReset }: { onReset: () => void }) {
  const { t } = useTranslation()
  return (
    <div className="my-10 flex flex-col items-center justify-center gap-3 rounded-[10px] border border-dashed border-border/80 bg-background-secondary/50 px-6 py-14 text-center">
      <span className="flex size-9 items-center justify-center rounded-full bg-background-overlay-secondary text-fg-tertiary">
        <FilterRegular aria-hidden className="size-4" />
      </span>
      <p className="max-w-md text-sm text-fg-secondary">{t('pod.jobs.no_matching_jobs')}</p>
      <Button type="button" variant="outline" size="sm" onClick={onReset}>
        {t('pod.jobs.clear_filters')}
      </Button>
    </div>
  )
}

export function EmptyJobsState({
  agents,
  onPickPreset
}: {
  agents: JobCandidateAgent[]
  onPickPreset: (preset: JobStarterPreset) => void
}) {
  const { t } = useTranslation()
  const canRunBackground = agents.some(agent => agent.canRunBackgroundJob)

  const starters: Array<{ key: string; icon: ReactNode; preset: JobStarterPreset; badge: string }> = [
    {
      key: 'briefing',
      icon: <CalendarClockRegular aria-hidden className="size-4 text-info-foreground" />,
      badge: t('pod.jobs.mode_cron'),
      preset: {
        mode: 'cron',
        title: t('pod.jobs.starters.briefing_title'),
        task: t('pod.jobs.starters.briefing_task'),
        expression: '0 9 * * 1-5'
      }
    },
    ...(canRunBackground
      ? [
          {
            key: 'research',
            icon: <SparkleRegular aria-hidden className="size-4 text-primary" />,
            badge: t('pod.jobs.mode_one_off'),
            preset: {
              mode: 'one_off' as const,
              title: t('pod.jobs.starters.research_title'),
              task: t('pod.jobs.starters.research_task')
            }
          }
        ]
      : []),
    {
      key: 'monitor',
      icon: <ClockRegular aria-hidden className="size-4 text-success-foreground" />,
      badge: t('pod.jobs.mode_cron'),
      preset: {
        mode: 'cron',
        title: t('pod.jobs.starters.monitor_title'),
        task: t('pod.jobs.starters.monitor_task'),
        expression: '0 * * * *'
      }
    }
  ]

  return (
    <div className="mx-auto my-8 grid w-full max-w-3xl gap-6 rounded-[12px] border border-border/75 bg-background-secondary/55 p-6 sm:p-8">
      <div className="grid gap-1.5">
        <h2 className="text-base font-semibold text-foreground">{t('pod.jobs.empty_title')}</h2>
        <p className="max-w-2xl text-sm leading-relaxed text-fg-secondary">{t('pod.jobs.empty_description')}</p>
      </div>

      {agents.length > 0 && (
        <div className="grid grid-cols-1 gap-3 sm:grid-cols-3">
          {starters.map(entry => (
            <button
              key={entry.key}
              type="button"
              onClick={() => onPickPreset(entry.preset)}
              className="group/starter flex cursor-pointer flex-col items-start gap-2.5 rounded-surface border border-border/80 bg-card p-4 text-start shadow-[0_1px_2px_rgb(0_0_0/0.03)] transition-[border-color,box-shadow] duration-(--duration-feedback) hover:border-control-edge hover:shadow-sm focus-visible:outline-2 focus-visible:outline-offset-2 focus-visible:outline-ring dark:shadow-none">
              <div className="flex w-full items-center gap-2">
                <span className="flex size-7 shrink-0 items-center justify-center rounded-control bg-background-secondary">
                  {entry.icon}
                </span>
                <Badge variant="secondary" size="sm">
                  {entry.badge}
                </Badge>
                <ArrowRightRegular
                  aria-hidden
                  className="ms-auto size-3.5 text-fg-quaternary opacity-0 transition-[opacity,transform] duration-(--duration-feedback) group-hover/starter:translate-x-0.5 group-hover/starter:opacity-100 group-focus-visible/starter:opacity-100"
                />
              </div>
              <span className="text-[13.5px] leading-5 font-medium text-foreground">{entry.preset.title}</span>
              <span className="line-clamp-2 text-xs leading-[17px] text-fg-secondary">{entry.preset.task}</span>
              {entry.preset.expression && (
                <span className="mt-auto rounded-mini bg-background-secondary px-1.5 py-0.5 font-mono text-[11px] leading-4 text-fg-tertiary">
                  {entry.preset.expression}
                </span>
              )}
            </button>
          ))}
        </div>
      )}
    </div>
  )
}
