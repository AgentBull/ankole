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
  useSidebar,
  type BoardTone
} from '@ankole/uikit'
import {
  CheckmarkCircleFilled,
  CheckmarkCircleRegular,
  CircleHalfFillRegular,
  CircleRegular,
  FilterRegular,
  RecordRegular,
  RecordStopRegular,
  type IconComponent
} from '@ankole/uikit/icons'
import { useMutation, useQuery, useQueryClient } from '@tanstack/react-query'
import { Link } from '@tanstack/react-router'
import { useRef, useState } from 'react'
import { useTranslation } from 'react-i18next'
import { podLocation } from '../common/browser-context'
import { formatDateTime, formatRelativeTime } from '../common/date-time'
import { ErrorBoundary } from '../common/error-boundary'
import { useSearchParams } from '../common/router'
import { stopConversationExecution, updatePodIssue } from './api/generated/sdk.gen'
import { ChatAvatar } from './chat/chat-avatar'
import { ExecutionStatusMark, executionStatusLabelKey, executionStatusTone } from './chat/execution-status'
import { executionProgressLabel } from './chat/linked-execution-card'
import { ContentError, ContentSkeleton } from './content-primitives'
import { PodPanelPresence, usePanelMotion, type PanelInputEvent } from './panel-motion'
import { scheduledWorkQuery, workItemsQuery, workKeys, workStatuses, type WorkItem, type WorkStatus } from './work-api'
import { WorkDetailPanel, type WorkRun } from './work-detail-panel'

/** Opens a card beside the board, on the card's lead run. */
type Open = (item: WorkItem, trigger: HTMLElement | null, event: PanelInputEvent) => void

const runKey = (run: WorkRun | null) => (run ? `${run.kind}:${run.id}` : null)

function parseRun(value: string | null): WorkRun | null {
  const [kind, id] = value?.split(':') ?? []
  return (kind === 'background_agent_job' || kind === 'workflow') && id ? { kind, id } : null
}

/**
 * The step that a column asks of a card dropped on it. Only three moves are a person's to make: start an Issue
 * that waits, accept a result, and reopen an accepted Issue. The other columns follow the room's real work. A
 * reopened Issue lands in To do when its request was never sent, whichever of the two columns took the card.
 */
function stepTo(item: WorkItem, column: WorkStatus): 'started' | 'done' | undefined {
  if (!item.tracked) return undefined
  if (column === 'working' && item.status === 'todo') return 'started'
  if (column === 'done' && (item.status === 'review' || item.status === 'todo')) return 'done'
  if ((column === 'review' || column === 'todo') && item.status === 'done') return 'started'
  return undefined
}

/**
 * The Work page: the background work that the viewer handed to Agents, by where it stands. A card opens beside the
 * board in the room layout of Chat, where the board keeps a narrow column and the run inspector takes the rest.
 */
export function WorkRoute() {
  const { t } = useTranslation()
  const { isMobile: mobile } = useSidebar()
  const [search, setSearch] = useSearchParams()
  const selected = search.get('issue')
  const run = parseRun(search.get('run'))
  const agents = search.getAll('agent')
  const returnFocus = useRef<HTMLElement | null>(null)
  const motion = usePanelMotion(!!selected)
  const show = (id: string | null, next: WorkRun | null, event?: PanelInputEvent) => {
    motion.prepare(!!id, event)
    setSearch(current => {
      if (id) current.set('issue', id)
      else current.delete('issue')
      if (id && next) current.set('run', runKey(next)!)
      else current.delete('run')
      return current
    })
  }
  const close = (event?: PanelInputEvent) => {
    show(null, null, event)
    if (returnFocus.current?.isConnected) returnFocus.current.focus({ preventScroll: true })
  }
  const open: Open = (item, trigger, event) => {
    const lead = leadRun(item)
    const next = lead ? { kind: lead.kind, id: lead.id } : null
    // As in Chat, opening the card that is already open closes it.
    if (selected === item.id && runKey(next) === runKey(run)) {
      close(event)
      return
    }
    returnFocus.current = trigger
    show(item.id, next, event)
  }
  const panel = (variant: 'panel' | 'sheet', id: string) => (
    <WorkDetailPanel
      id={id}
      run={run}
      variant={variant}
      finalFocus={returnFocus}
      close={close}
      select={next => show(id, next)}
    />
  )
  return (
    <div className="pod-chat-room-body h-full">
      <section className="pod-chat-room-main overflow-hidden">
        <div className="flex min-h-0 flex-1 flex-col px-6 pt-2 @3xl:px-10">
          <div className="mb-4 flex min-w-0 items-center gap-2">
            <h1 className="title-page min-w-0 truncate">{t('pod.work.title')}</h1>
            <WorkFilter
              selected={agents}
              onChange={next =>
                setSearch(current => {
                  current.delete('agent')
                  for (const uid of next) current.append('agent', uid)
                  return current
                })
              }
            />
            <WorkingAgents />
          </div>
          <div className="@container min-h-0 flex-1 space-y-8 overflow-auto pb-6">
            <WorkItems selected={selected} agents={agents} open={open} />
            <ScheduledWork />
          </div>
        </div>
      </section>
      {mobile ? (
        selected && panel('sheet', selected)
      ) : (
        <PodPanelPresence animate={motion.animate}>
          {selected && (
            <ErrorBoundary
              key="detail"
              variant="panel"
              className="m-3 w-96 shrink-0 self-start"
              resetKeys={[selected, runKey(run)]}>
              {panel('panel', selected)}
            </ErrorBoundary>
          )}
        </PodPanelPresence>
      )}
    </div>
  )
}

// Each column marks where its work stands with a status icon in that status's hue.
const columns: Record<WorkStatus, { icon: IconComponent; tone: BoardTone }> = {
  todo: { icon: CircleRegular, tone: 'gray' },
  working: { icon: CircleHalfFillRegular, tone: 'blue' },
  waiting: { icon: RecordRegular, tone: 'amber' },
  review: { icon: CheckmarkCircleRegular, tone: 'purple' },
  done: { icon: CheckmarkCircleFilled, tone: 'green' }
}

/** The live run that a card leads with and opens: the latest one. */
function leadRun(item: WorkItem) {
  return item.runs.reduce<WorkItem['runs'][number] | undefined>(
    (newest, run) => (!newest || run.createdAt > newest.createdAt ? run : newest),
    undefined
  )
}

/** The Agents filter of the board. The page keeps the chosen Agents in its `agent` search parameters. */
function WorkFilter({ selected, onChange }: { selected: string[]; onChange(next: string[]): void }) {
  const { t } = useTranslation()
  const items = useQuery(workItemsQuery)
  const agents = [
    ...new Map((items.data ?? []).flatMap(item => (item.agent ? [[item.agent.uid, item.agent.name] as const] : [])))
  ]
  return (
    <DropdownMenu>
      <DropdownMenuTrigger
        render={<Button size={selected.length ? 'sm' : 'icon-sm'} variant="ghost" />}
        aria-label={t('pod.work.filter')}
        title={t('pod.work.filter')}>
        <FilterRegular aria-hidden />
        {selected.length > 0 && (
          <Badge size="sm" variant="info">
            {selected.length}
          </Badge>
        )}
      </DropdownMenuTrigger>
      <DropdownMenuContent align="start" className="min-w-56">
        <DropdownMenuGroup>
          <DropdownMenuLabel>{t('pod.work.filter_agent')}</DropdownMenuLabel>
          {agents.length ? (
            agents.map(([uid, name]) => (
              <DropdownMenuCheckboxItem
                key={uid}
                checked={selected.includes(uid)}
                onCheckedChange={checked =>
                  onChange(checked ? [...selected, uid] : selected.filter(chosen => chosen !== uid))
                }>
                <ChatAvatar name={name} agent size="xs" />
                <span className="min-w-0 flex-1 truncate">{name}</span>
              </DropdownMenuCheckboxItem>
            ))
          ) : (
            <DropdownMenuItem disabled>{t('pod.work.filter_none')}</DropdownMenuItem>
          )}
        </DropdownMenuGroup>
        {selected.length > 0 && (
          <>
            <DropdownMenuSeparator />
            <DropdownMenuItem onClick={() => onChange([])}>{t('pod.work.filter_clear')}</DropdownMenuItem>
          </>
        )}
      </DropdownMenuContent>
    </DropdownMenu>
  )
}

/** The Agents whose background work is running now, as the board's header names them. */
function WorkingAgents() {
  const { t } = useTranslation()
  const items = useQuery(workItemsQuery)
  const agents = [
    ...new Map(
      (items.data ?? []).flatMap(item =>
        item.agent && item.runs.some(run => executionStatusTone(run.status) === 'running')
          ? [[item.agent.uid, item.agent.name] as const]
          : []
      )
    )
  ]
  if (!agents.length) return null
  return (
    <BoardPresence
      className="ms-auto"
      avatars={agents.slice(0, 3).map(([uid, name]) => (
        <ChatAvatar key={uid} name={name} agent size="xs" />
      ))}>
      {t('pod.work.agents_working', { count: agents.length })}
    </BoardPresence>
  )
}

function WorkItems({ selected, agents, open }: { selected: string | null; agents: string[]; open: Open }) {
  const { t } = useTranslation()
  const client = useQueryClient()
  const items = useQuery(workItemsQuery)
  const move = useMutation({
    mutationFn: ({ item, column }: { item: WorkItem; column: WorkStatus }) =>
      updatePodIssue({ path: { id: item.id }, body: { data: { status: stepTo(item, column) } } }),
    // The card moves at once; the server's answer or the next room event confirms it.
    onMutate: ({ item, column }) => {
      const previous = client.getQueryData<WorkItem[]>(workKeys.items)
      client.setQueryData<WorkItem[]>(workKeys.items, rows =>
        rows?.map(row => (row.id === item.id ? { ...row, status: column } : row))
      )
      return { previous }
    },
    onError: (_error, _input, context) => {
      if (context) client.setQueryData(workKeys.items, context.previous)
    },
    onSettled: () => void client.invalidateQueries({ queryKey: workKeys.all })
  })
  if (items.isPending) return <ContentSkeleton variant="list" rows={6} />
  if (items.error && !items.data) return <ContentError error={items.error} retry={() => void items.refetch()} />
  if (!items.data?.length) return <p className="py-10 text-center text-sm text-fg-tertiary">{t('pod.work.empty')}</p>
  const rows = agents.length ? items.data.filter(item => item.agent && agents.includes(item.agent.uid)) : items.data
  return (
    <>
      <ContentError error={move.error || items.error} />
      <WorkBoard items={rows} selected={selected} open={open} move={(item, column) => move.mutate({ item, column })} />
    </>
  )
}

function WorkBoard({
  items,
  selected,
  open,
  move
}: {
  items: WorkItem[]
  selected: string | null
  open: Open
  move(item: WorkItem, column: WorkStatus): void
}) {
  const { t } = useTranslation()
  // A drop target reads the dragged card from here, because a drag event hides its data until the drop.
  const [dragged, setDragged] = useState<WorkItem>()
  const [over, setOver] = useState<WorkStatus>()
  return (
    <Board className="min-h-64 pb-2">
      {workStatuses.map(status => {
        const column = items.filter(item => item.status === status)
        const accepts = !!dragged && !!stepTo(dragged, status)
        const label = t(`pod.work.status.${status}`)
        const { icon: Icon, tone } = columns[status]
        return (
          <BoardColumn
            key={status}
            dropTarget={over === status}
            aria-label={label}
            onDragOver={event => {
              if (!accepts) return
              event.preventDefault()
              if (over !== status) setOver(status)
            }}
            onDragLeave={event => {
              if (!event.currentTarget.contains(event.relatedTarget as Node | null)) setOver(undefined)
            }}
            onDrop={event => {
              event.preventDefault()
              setOver(undefined)
              if (dragged && accepts) move(dragged, status)
            }}>
            <BoardColumnHeader icon={<Icon />} tone={tone} count={column.length}>
              {label}
            </BoardColumnHeader>
            {column.map(item => (
              <WorkCard
                key={item.id}
                item={item}
                active={selected === item.id}
                open={open}
                onDrag={dragging => {
                  setDragged(dragging ? item : undefined)
                  if (!dragging) setOver(undefined)
                }}
              />
            ))}
          </BoardColumn>
        )
      })}
    </Board>
  )
}

/**
 * One work item on the board, in three rows. The first names the kind of its lead run and that run's progress, and
 * shows how the run stands with its Stop action; the second is the title; the third is the Agent and when the work
 * last moved.
 */
function WorkCard({
  item,
  active,
  open,
  onDrag
}: {
  item: WorkItem
  active: boolean
  open: Open
  onDrag(dragging: boolean): void
}) {
  const { t, i18n } = useTranslation()
  const title = useRef<HTMLElement | null>(null)
  const lead = leadRun(item)
  const status = lead && executionStatusLabelKey(lead.status)
  const stoppable = lead?.stoppable ? lead : item.runs.find(run => run.stoppable)
  const client = useQueryClient()
  const stop = useMutation({
    mutationFn: (run: WorkItem['runs'][number]) =>
      stopConversationExecution({ path: { id: item.id, kind: run.kind, run_id: Number(run.id) } }),
    onSuccess: () => void client.invalidateQueries({ queryKey: workKeys.all })
  })
  // How far the lead run has come, else what kind of run it is; a card without a live run names an Issue.
  const facts = lead
    ? [
        executionProgressLabel(lead, t) ??
          t(lead.kind === 'workflow' ? 'pod.chat_timeline.workflow' : 'pod.chat_timeline.background_work'),
        item.runs.length > 1 ? `+${item.runs.length - 1}` : undefined
      ]
    : [item.tracked ? t('pod.work.issue') : undefined]
  return (
    <BoardCard
      selected={active}
      draggable={item.tracked}
      aria-current={active ? 'true' : undefined}
      className="cursor-pointer"
      onClick={event => {
        // The whole card opens its work; its own controls keep their click.
        if ((event.target as HTMLElement | null)?.closest('button')) return
        open(item, title.current, event.nativeEvent)
      }}
      onDragStart={event => {
        event.dataTransfer.effectAllowed = 'move'
        event.dataTransfer.setData('text/plain', item.title)
        onDrag(true)
      }}
      onDragEnd={() => onDrag(false)}>
      <BoardCardHeader>
        <span className="min-w-0 truncate">{facts.filter(Boolean).join(' · ')}</span>
        {lead && (
          <BoardCardAside>
            <ExecutionStatusMark status={lead.status} />
            {status ? t(status) : lead.status}
            {stoppable && (
              <BoardCardActions>
                <Button
                  size="icon-xs"
                  variant="ghost"
                  disabled={stop.isPending}
                  aria-label={`${t('pod.chat_timeline.execution_stop_action')} ${stoppable.title}`}
                  title={t(
                    stop.isPending ? 'pod.chat_timeline.execution_stopping' : 'pod.chat_timeline.execution_stop_action'
                  )}
                  onClick={() => stop.mutate(stoppable)}>
                  <RecordStopRegular aria-hidden />
                </Button>
              </BoardCardActions>
            )}
          </BoardCardAside>
        )}
      </BoardCardHeader>
      <BoardCardTitle
        ref={node => {
          title.current = node
        }}
        render={<button type="button" />}
        onClick={event => open(item, event.currentTarget, event.nativeEvent)}>
        {item.title || t('pod.content.untitled')}
      </BoardCardTitle>
      <BoardCardFooter>
        {item.agent && (
          <>
            <ChatAvatar name={item.agent.name} agent size="xs" />
            <span className="min-w-0 truncate">{item.agent.name}</span>
          </>
        )}
        <BoardCardAside>{formatRelativeTime(item.lastActivityAt, i18n.language)}</BoardCardAside>
      </BoardCardFooter>
      <ContentError error={stop.error} />
    </BoardCard>
  )
}

/** The recurring rules and pending checkbacks of the viewer's rooms. Each row opens the room that manages it. */
function ScheduledWork() {
  const { t, i18n } = useTranslation()
  const schedules = useQuery(scheduledWorkQuery)
  if (schedules.error && !schedules.data) {
    return <ContentError error={schedules.error} retry={() => void schedules.refetch()} />
  }
  if (!schedules.data?.length) return null
  return (
    <section aria-label={t('pod.work.scheduled')}>
      <h2 className="mb-2 flex items-center gap-2 text-[13px] font-medium">
        {t('pod.work.scheduled')}
        <span className="text-fg-tertiary tabular-nums">{schedules.data.length}</span>
      </h2>
      <ul className="grid gap-0.5">
        {schedules.data.map(row => (
          <li key={`${row.kind}:${row.id}`}>
            {/* A schedule changes only through its Agent, so the row opens the conversation that manages it. */}
            <Link
              to={podLocation(`/conversations/${row.conversationID}`).pathname}
              className="flex min-h-9 w-full items-center gap-3 rounded-control px-3 py-1 text-left text-[13px] leading-5 text-inherit no-underline hover:bg-accent focus-visible:bg-accent focus-visible:outline-2 focus-visible:outline-ring">
              <span className="hidden w-24 shrink-0 text-xs text-fg-tertiary @md:block">
                {t(`pod.work.schedule_kind.${row.kind}`)}
              </span>
              <span className="min-w-0 flex-1 truncate">
                {row.title || row.conversationTitle || t('pod.content.untitled')}
              </span>
              <span className="hidden w-40 shrink-0 truncate text-xs text-fg-secondary @2xl:block">
                {row.agentName}
              </span>
              <span className="shrink-0 text-xs text-fg-secondary @md:w-44">
                {row.status === 'paused'
                  ? t('pod.work.paused')
                  : row.dueAt
                    ? t('pod.work.next_run', { time: formatDateTime(row.dueAt, i18n.language) })
                    : ''}
              </span>
            </Link>
          </li>
        ))}
      </ul>
    </section>
  )
}
