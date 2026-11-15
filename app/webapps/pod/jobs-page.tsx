import {
  Badge,
  Board,
  BoardCard,
  BoardCardActions,
  BoardCardAside,
  BoardCardFooter,
  BoardCardHeader,
  BoardCardTitle,
  BoardColumn,
  BoardColumnHeader,
  BoardPresence,
  Button,
  DropdownMenu,
  DropdownMenuCheckboxItem,
  DropdownMenuContent,
  DropdownMenuGroup,
  DropdownMenuItem,
  DropdownMenuLabel,
  DropdownMenuSeparator,
  DropdownMenuTrigger,
  Tabs,
  TabsList,
  TabsTrigger,
  toast,
  useSidebar,
  type BoardTone
} from '@ankole/uikit'
import {
  AddRegular,
  CalendarClockRegular,
  CheckmarkCircleFilled,
  CircleHalfFillRegular,
  ClockRegular,
  FilterRegular,
  FlashRegular,
  PauseCircleRegular,
  StopFilled
} from '@ankole/uikit/icons'
import { useMutation, useQuery, useQueryClient } from '@tanstack/react-query'
import type { TFunction } from 'i18next'
import { useCallback, useMemo, useRef, useState, type ReactNode } from 'react'
import { useTranslation } from 'react-i18next'
import { formatRelativeTime } from '../common/date-time'
import { requestErrorMessage } from '../common/request-errors'
import { useSearchParams } from '../common/router'
import { stopPodJobExecution } from './api/generated/sdk.gen'
import { ChatAvatar } from './chat/chat-avatar'
import { ExecutionStatusMark, isLiveExecutionStatus } from './chat/execution-status'
import { ContentError, ContentLoading } from './content-primitives'
import { JobCreateDialog, type JobStarterPreset } from './job-create-dialog'
import {
  jobColumns,
  jobsBoardQuery,
  jobsError,
  jobsKeys,
  type JobBoardItem,
  type JobCandidateAgent,
  type JobColumn
} from './jobs-api'
import { JobsDetailPanel, type JobExecutionRef } from './jobs-detail-panel'
import { PodPanelPresence, usePanelMotion, type PanelInputEvent } from './panel-motion'
import './chat.css'

const JOB_KINDS: ReadonlyArray<JobBoardItem['kind']> = [
  'background_agent_job',
  'workflow',
  'cron',
  'automation_job',
  'checkback'
]

function parseRunParam(raw: string | null): JobExecutionRef | null {
  if (!raw) return null
  const colon = raw.indexOf(':')
  if (colon <= 0) return null
  const kind = raw.slice(0, colon)
  const id = raw.slice(colon + 1).trim()
  if (!id) return null
  if (kind === 'background_agent_job' || kind === 'workflow') return { kind, id }
  return null
}

function columnMeta(column: JobColumn): { icon: ReactNode; tone: BoardTone } {
  switch (column) {
    case 'scheduled':
      return { icon: <ClockRegular />, tone: 'gray' }
    case 'running':
      return { icon: <CircleHalfFillRegular />, tone: 'blue' }
    case 'completed':
      return { icon: <CheckmarkCircleFilled />, tone: 'green' }
  }
}

export function JobsRoute() {
  const { t } = useTranslation()
  const { isMobile } = useSidebar()
  const [searchParams, setSearchParams] = useSearchParams()
  const board = useQuery(jobsBoardQuery)

  const selectedID = searchParams.get('item')?.trim() || undefined
  const selectedRun = useMemo(() => parseRunParam(searchParams.get('run')), [searchParams])
  const agentFilter = searchParams.get('agent')?.trim() || undefined
  const kindFilter = searchParams.get('kind')?.trim() as JobBoardItem['kind'] | undefined
  const viewMode: 'status' | 'agent' = searchParams.get('view') === 'agent' ? 'agent' : 'status'

  const panelMotion = usePanelMotion(Boolean(selectedID))
  const triggerElement = useRef<HTMLElement | null>(null)
  const createButtonRef = useRef<HTMLButtonElement | null>(null)

  const [createOpen, setCreateOpen] = useState(false)
  const [starterPreset, setStarterPreset] = useState<JobStarterPreset | null>(null)

  const selectCard = useCallback(
    (nextID: string | undefined, event?: PanelInputEvent, source?: HTMLElement | null) => {
      if (source) triggerElement.current = source
      panelMotion.prepare(Boolean(nextID), event)
      setSearchParams(
        prev => {
          const next = new URLSearchParams(prev)
          if (nextID) {
            next.set('item', nextID)
          } else {
            next.delete('item')
          }
          next.delete('run')
          return next
        },
        { replace: !nextID, preventScrollReset: true }
      )
    },
    [panelMotion, setSearchParams]
  )

  const selectRun = useCallback(
    (nextRun: JobExecutionRef | null) => {
      setSearchParams(
        prev => {
          const next = new URLSearchParams(prev)
          if (nextRun) {
            next.set('run', `${nextRun.kind}:${nextRun.id}`)
          } else {
            next.delete('run')
          }
          return next
        },
        { replace: true, preventScrollReset: true }
      )
    },
    [setSearchParams]
  )

  const updateParam = (key: string, value: string | undefined) => {
    setSearchParams(
      prev => {
        const next = new URLSearchParams(prev)
        if (value) next.set(key, value)
        else next.delete(key)
        return next
      },
      { replace: true, preventScrollReset: true }
    )
  }

  const clearFilters = () => {
    setSearchParams(
      prev => {
        const next = new URLSearchParams(prev)
        next.delete('agent')
        next.delete('kind')
        return next
      },
      { replace: true, preventScrollReset: true }
    )
  }

  const allItems = board.data?.items ?? []
  const agents = board.data?.agents ?? []

  const filteredItems = useMemo(
    () =>
      allItems.filter(item => {
        if (agentFilter && item.agentUID !== agentFilter) return false
        if (kindFilter && item.kind !== kindFilter) return false
        return true
      }),
    [agentFilter, allItems, kindFilter]
  )

  const selectedItem = useMemo(
    () => (selectedID ? allItems.find(item => item.id === selectedID) : undefined),
    [allItems, selectedID]
  )

  const agentAvatarByUID = useMemo(() => new Map(agents.map(agent => [agent.uid, agent.avatarURL])), [agents])

  const workingAgents = useMemo(() => {
    const byUID = new Map<string, { uid: string; name: string; avatarURL?: string | null }>()
    for (const item of allItems) {
      if (item.column !== 'running' || !item.agentUID) continue
      if (!byUID.has(item.agentUID)) {
        const candidate = agents.find(agent => agent.uid === item.agentUID)
        byUID.set(item.agentUID, {
          uid: item.agentUID,
          name: item.agentName || candidate?.displayName || `@${item.agentUID}`,
          avatarURL: candidate?.avatarURL
        })
      }
    }
    return [...byUID.values()]
  }, [agents, allItems])

  const activeFilterCount = (agentFilter ? 1 : 0) + (kindFilter ? 1 : 0)

  const openCreateWithPreset = (preset: JobStarterPreset | null) => {
    setStarterPreset(preset)
    setCreateOpen(true)
  }

  return (
    <div className="pod-chat-room-body h-full overflow-hidden">
      <div className="pod-chat-room-main overflow-y-auto px-4 py-5 md:px-8 md:py-6">
        <header className="mb-5 flex flex-wrap items-center justify-between gap-3">
          <div className="flex min-w-0 flex-wrap items-center gap-3">
            <h1 className="text-lg font-semibold tracking-tight text-foreground">{t('pod.jobs.title')}</h1>
            {workingAgents.length > 0 && (
              <BoardPresence
                avatars={workingAgents.slice(0, 4).map(agent => (
                  <ChatAvatar key={agent.uid} name={agent.name} src={agent.avatarURL} agent round size="xs" />
                ))}>
                {workingAgents.length === 1
                  ? t('pod.jobs.working_single', { name: workingAgents[0]!.name })
                  : t('pod.jobs.working_count', { count: workingAgents.length })}
              </BoardPresence>
            )}
          </div>

          <div className="flex flex-wrap items-center gap-2">
            <Tabs
              value={viewMode}
              onValueChange={value => updateParam('view', value === 'agent' ? 'agent' : undefined)}>
              <TabsList variant="object" aria-label={t('pod.jobs.view_label')}>
                <TabsTrigger value="status">{t('pod.jobs.view_status')}</TabsTrigger>
                <TabsTrigger value="agent">{t('pod.jobs.view_agent')}</TabsTrigger>
              </TabsList>
            </Tabs>

            <DropdownMenu>
              <DropdownMenuTrigger
                render={
                  <Button type="button" variant="outline" size="sm">
                    <FilterRegular aria-hidden />
                    {t('pod.jobs.filter')}
                    {activeFilterCount > 0 && (
                      <Badge variant="info" size="sm">
                        {activeFilterCount}
                      </Badge>
                    )}
                  </Button>
                }
              />
              <DropdownMenuContent align="end" className="min-w-52">
                {agents.length > 0 && (
                  <>
                    <DropdownMenuGroup>
                      <DropdownMenuLabel>{t('pod.jobs.field_agent')}</DropdownMenuLabel>
                      {agents.map(agent => (
                        <DropdownMenuCheckboxItem
                          key={agent.uid}
                          checked={agentFilter === agent.uid}
                          onCheckedChange={checked => updateParam('agent', checked ? agent.uid : undefined)}>
                          {agent.displayName}
                        </DropdownMenuCheckboxItem>
                      ))}
                    </DropdownMenuGroup>
                    <DropdownMenuSeparator />
                  </>
                )}
                <DropdownMenuGroup>
                  <DropdownMenuLabel>{t('pod.jobs.filter_kind')}</DropdownMenuLabel>
                  {JOB_KINDS.map(kind => (
                    <DropdownMenuCheckboxItem
                      key={kind}
                      checked={kindFilter === kind}
                      onCheckedChange={checked => updateParam('kind', checked ? kind : undefined)}>
                      {t(`pod.jobs.kinds.${kind}`)}
                    </DropdownMenuCheckboxItem>
                  ))}
                </DropdownMenuGroup>
                {activeFilterCount > 0 && (
                  <>
                    <DropdownMenuSeparator />
                    <DropdownMenuItem onClick={clearFilters}>{t('pod.jobs.clear_filters')}</DropdownMenuItem>
                  </>
                )}
              </DropdownMenuContent>
            </DropdownMenu>

            {agents.length > 0 && (
              <Button ref={createButtonRef} type="button" size="sm" onClick={() => openCreateWithPreset(null)}>
                <AddRegular aria-hidden />
                {t('pod.jobs.new_job')}
              </Button>
            )}
          </div>
        </header>

        {board.isPending ? (
          <ContentLoading className="py-16" />
        ) : board.error ? (
          <ContentError error={jobsError(board.error)} retry={() => void board.refetch()} />
        ) : allItems.length === 0 ? (
          <EmptyJobsState agents={agents} onPickPreset={openCreateWithPreset} />
        ) : viewMode === 'agent' ? (
          <AgentColumnsBoard items={filteredItems} agents={agents} selectedID={selectedID} onSelect={selectCard} />
        ) : (
          <StatusColumnsBoard
            items={filteredItems}
            agentAvatarByUID={agentAvatarByUID}
            selectedID={selectedID}
            onSelect={selectCard}
          />
        )}
      </div>

      {isMobile ? (
        selectedID ? (
          <JobsDetailPanel
            id={selectedID}
            run={selectedRun}
            item={selectedItem}
            agents={agents}
            variant="sheet"
            finalFocus={triggerElement}
            close={event => selectCard(undefined, event)}
            selectRun={selectRun}
          />
        ) : null
      ) : (
        <PodPanelPresence animate={panelMotion.animate}>
          {selectedID ? (
            <JobsDetailPanel
              key="jobs-detail"
              id={selectedID}
              run={selectedRun}
              item={selectedItem}
              agents={agents}
              variant="panel"
              finalFocus={triggerElement}
              close={event => selectCard(undefined, event)}
              selectRun={selectRun}
            />
          ) : null}
        </PodPanelPresence>
      )}

      <JobCreateDialog
        open={createOpen}
        onOpenChange={setCreateOpen}
        agents={agents}
        preset={starterPreset}
        returnFocus={createButtonRef}
        onCreated={created => selectCard(created.id)}
      />
    </div>
  )
}

function StatusColumnsBoard({
  items,
  agentAvatarByUID,
  selectedID,
  onSelect
}: {
  items: JobBoardItem[]
  agentAvatarByUID: Map<string, string | null | undefined>
  selectedID?: string
  onSelect: (id: string, event?: PanelInputEvent, source?: HTMLElement | null) => void
}) {
  const { t } = useTranslation()

  return (
    <Board>
      {jobColumns.map(column => {
        const meta = columnMeta(column)
        const cards = items
          .filter(item => item.column === column)
          .sort((a, b) => {
            if (column === 'running' && a.attention !== b.attention) {
              return a.attention ? -1 : 1
            }
            return 0
          })

        return (
          <BoardColumn key={column} aria-label={t(`pod.jobs.columns.${column}`)}>
            <BoardColumnHeader icon={meta.icon} tone={meta.tone} count={cards.length}>
              {t(`pod.jobs.columns.${column}`)}
            </BoardColumnHeader>
            {cards.map(card => (
              <JobCard
                key={card.id}
                item={card}
                agentAvatarURL={card.agentUID ? agentAvatarByUID.get(card.agentUID) : undefined}
                selected={selectedID === card.id}
                onSelect={(event, button) => onSelect(card.id, event, button)}
              />
            ))}
          </BoardColumn>
        )
      })}
    </Board>
  )
}

function AgentColumnsBoard({
  items,
  agents,
  selectedID,
  onSelect
}: {
  items: JobBoardItem[]
  agents: JobCandidateAgent[]
  selectedID?: string
  onSelect: (id: string, event?: PanelInputEvent, source?: HTMLElement | null) => void
}) {
  const { t } = useTranslation()

  const columns = useMemo(() => {
    const orderRank = (item: JobBoardItem) => {
      if (item.attention) return 0
      if (item.column === 'running') return 1
      if (item.column === 'scheduled') return 2
      return 3
    }

    const byAgent = new Map<string, { key: string; title: string; avatarURL?: string | null; cards: JobBoardItem[] }>()
    for (const agent of agents) {
      byAgent.set(agent.uid, {
        key: agent.uid,
        title: agent.displayName,
        avatarURL: agent.avatarURL,
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
        cards: [...automationCards].sort((a, b) => orderRank(a) - orderRank(b))
      })
    }
    return result
  }, [agents, items, t])

  return (
    <Board>
      {columns.map(column => (
        <BoardColumn key={column.key} aria-label={column.title}>
          <BoardColumnHeader
            icon={
              column.key === '__automations__' ? (
                <FlashRegular />
              ) : (
                <ChatAvatar name={column.title} src={column.avatarURL} agent size="xs" />
              )
            }
            tone={column.cards.some(card => card.column === 'running') ? 'blue' : 'gray'}
            count={column.cards.length}>
            {column.title}
          </BoardColumnHeader>
          {column.cards.map(card => (
            <JobCard
              key={card.id}
              item={card}
              agentAvatarURL={column.avatarURL}
              selected={selectedID === card.id}
              onSelect={(event, button) => onSelect(card.id, event, button)}
            />
          ))}
        </BoardColumn>
      ))}
    </Board>
  )
}

function JobCard({
  item,
  agentAvatarURL,
  selected,
  onSelect
}: {
  item: JobBoardItem
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

  const metaDetail = cardProgressSummary(item, t)
  const timestamp =
    item.column === 'scheduled' && item.nextRunAt
      ? formatRelativeTime(item.nextRunAt, i18n.language)
      : formatRelativeTime(item.updatedAt, i18n.language)

  return (
    <BoardCard selected={selected}>
      <BoardCardHeader>
        {item.cardType === 'routine' && <CalendarClockRegular aria-hidden className="size-3.5 shrink-0" />}
        <span className="truncate">{t(`pod.jobs.kinds.${item.kind}`)}</span>
        {metaDetail && <span className="truncate font-mono text-[11px]">{metaDetail}</span>}
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

      <BoardCardFooter>
        {item.agentUID ? (
          <>
            <ChatAvatar name={item.agentName || `@${item.agentUID}`} src={agentAvatarURL} agent size="xs" />
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

function EmptyJobsState({
  agents,
  onPickPreset
}: {
  agents: JobCandidateAgent[]
  onPickPreset: (preset: JobStarterPreset) => void
}) {
  const { t } = useTranslation()
  const canRunBackground = agents.some(agent => agent.canRunBackgroundJob)

  const starters: Array<{ key: string; preset: JobStarterPreset; badge: string }> = [
    {
      key: 'briefing',
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
    <div className="mx-auto my-8 grid max-w-3xl gap-6 rounded-surface border border-border bg-background-secondary/40 p-6">
      <div className="grid gap-1.5">
        <h2 className="text-base font-semibold text-foreground">{t('pod.jobs.empty_title')}</h2>
        <p className="text-sm text-fg-secondary">{t('pod.jobs.empty_description')}</p>
      </div>

      {agents.length > 0 && (
        <div className="grid grid-cols-1 gap-3 sm:grid-cols-3">
          {starters.map(entry => (
            <button
              key={entry.key}
              type="button"
              onClick={() => onPickPreset(entry.preset)}
              className="flex flex-col items-start gap-2 rounded-surface border border-border bg-card p-3.5 text-start transition-shadow hover:shadow-sm">
              <Badge variant="secondary" size="sm">
                {entry.badge}
              </Badge>
              <span className="text-sm font-medium text-foreground">{entry.preset.title}</span>
              <span className="line-clamp-2 text-xs text-fg-secondary">{entry.preset.task}</span>
            </button>
          ))}
        </div>
      )}
    </div>
  )
}
