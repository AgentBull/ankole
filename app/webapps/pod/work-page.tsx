import { Button, Tabs, TabsList, TabsTrigger, useSidebar } from '@ankole/uikit'
import { RiAddLine, RiStopCircleLine } from '@remixicon/react'
import { useMutation, useQuery, useQueryClient } from '@tanstack/react-query'
import { lazy, Suspense, useRef, useState } from 'react'
import { useTranslation } from 'react-i18next'
import { formatDateTime, formatRelativeTime } from '../common/date-time'
import { useSearchParams } from '../common/router'
import { stopConversationExecution, updatePodIssue } from './api/generated/sdk.gen'
import { ChatAvatar } from './chat/chat-avatar'
import { ExecutionStatusMark, RunningElapsed, executionStatusLabelKey } from './chat/execution-status'
import { executionProgressLabel } from './chat/linked-execution-card'
import { ContentError, ContentSkeleton } from './content-primitives'
import { IssueCreateDialog } from './issue-create-dialog'
import { scheduledWorkQuery, workItemsQuery, workKeys, workStatuses, type WorkItem, type WorkStatus } from './work-api'

const IssuePanel = lazy(() => import('./issue-panel').then(module => ({ default: module.IssuePanel })))

type Open = (id: string, trigger?: HTMLElement | null) => void

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

/** The Work page: the background work that the viewer handed to Agents, by where it stands. */
export function WorkRoute() {
  const { t } = useTranslation()
  const { isMobile: mobile } = useSidebar()
  const [search, setSearch] = useSearchParams()
  const layout = search.get('layout') === 'list' ? 'list' : 'board'
  const selected = search.get('issue')
  const [creating, setCreating] = useState(false)
  const returnFocus = useRef<HTMLElement | null>(null)
  const open = (id: string | null, trigger?: HTMLElement | null) => {
    if (trigger) returnFocus.current = trigger
    setSearch(current => {
      if (id) current.set('issue', id)
      else current.delete('issue')
      return current
    })
  }
  return (
    <div className="flex h-full min-h-0">
      <section className="flex min-w-0 flex-1 flex-col overflow-hidden px-6 pt-2 md:px-10">
        <div className="mb-4 flex flex-wrap items-center justify-between gap-3">
          <h1 className="title-page min-w-0 truncate">{t('pod.sidebar.tabs.work')}</h1>
          <div className="flex items-center gap-2">
            <Tabs
              value={layout}
              onValueChange={value =>
                setSearch(current => {
                  if (value === 'list') current.set('layout', 'list')
                  else current.delete('layout')
                  return current
                })
              }>
              <TabsList aria-label={t('pod.work.layout')}>
                <TabsTrigger value="board">{t('pod.work.board')}</TabsTrigger>
                <TabsTrigger value="list">{t('pod.work.list')}</TabsTrigger>
              </TabsList>
            </Tabs>
            <Button size="sm" onClick={() => setCreating(true)}>
              <RiAddLine aria-hidden />
              {t('pod.work.new_issue')}
            </Button>
          </div>
        </div>
        <div className="min-h-0 flex-1 space-y-8 overflow-auto pb-6">
          <WorkItems layout={layout} selected={selected} open={open} />
          <ScheduledWork open={open} />
        </div>
      </section>
      <Suspense fallback={null}>
        <IssuePanel id={selected} mobile={mobile} close={() => open(null)} returnFocus={returnFocus} />
      </Suspense>
      <IssueCreateDialog open={creating} onOpenChange={setCreating} onCreated={item => open(item.id)} />
    </div>
  )
}

function WorkItems({ layout, selected, open }: { layout: 'board' | 'list'; selected: string | null; open: Open }) {
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
  const rows = items.data ?? []
  if (!rows.length) return <p className="py-10 text-center text-sm text-fg-tertiary">{t('pod.work.empty')}</p>
  return (
    <>
      <ContentError error={move.error || items.error} />
      {layout === 'list' ? (
        <WorkList items={rows} selected={selected} open={open} />
      ) : (
        <WorkBoard
          items={rows}
          selected={selected}
          open={open}
          move={(item, column) => move.mutate({ item, column })}
        />
      )}
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
    <div className="flex min-h-64 items-start gap-3 pb-2">
      {workStatuses.map(status => {
        const column = items.filter(item => item.status === status)
        const accepts = !!dragged && !!stepTo(dragged, status)
        return (
          <section
            key={status}
            aria-label={t(`pod.work.status.${status}`)}
            className={`min-h-24 min-w-52 flex-1 basis-0 space-y-2 rounded-control bg-muted/40 p-3 transition-colors ${over === status ? 'bg-accent/60 ring-2 ring-primary/40' : ''}`}
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
            <h2 className="flex items-center gap-2 text-[13px] font-medium">
              {t(`pod.work.status.${status}`)}
              <span className="text-fg-tertiary tabular-nums">{column.length}</span>
            </h2>
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
          </section>
        )
      })}
    </div>
  )
}

/**
 * One work item on the board. Each live Background Agent Job or Workflow shows the mark, the status, the progress,
 * and the running time that its card shows in the room, laid out for a narrow column.
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
  const { t } = useTranslation()
  const title = useRef<HTMLButtonElement>(null)
  const stoppable = item.runs.find(run => run.stoppable)
  const client = useQueryClient()
  const stop = useMutation({
    mutationFn: (run: WorkItem['runs'][number]) =>
      stopConversationExecution({ path: { id: item.id, kind: run.kind, run_id: Number(run.id) } }),
    onSuccess: () => void client.invalidateQueries({ queryKey: workKeys.all })
  })
  return (
    <article
      draggable={item.tracked}
      aria-current={active ? 'true' : undefined}
      className={`cursor-pointer rounded-control border bg-background p-3 text-[13px] leading-5 ${active ? 'border-primary' : 'border-border'}`}
      onClick={event => {
        // The whole card opens the room; its own controls keep their click.
        if ((event.target as HTMLElement | null)?.closest('button')) return
        open(item.id, title.current)
      }}
      onDragStart={event => {
        event.dataTransfer.effectAllowed = 'move'
        event.dataTransfer.setData('text/plain', item.title)
        onDrag(true)
      }}
      onDragEnd={() => onDrag(false)}>
      <button
        ref={title}
        type="button"
        className="line-clamp-3 w-full rounded-mini text-left font-medium break-words hover:underline focus-visible:outline-2 focus-visible:outline-ring"
        onClick={event => open(item.id, event.currentTarget)}>
        {item.title || t('pod.content.untitled')}
      </button>
      {item.runs.map(run => {
        const status = executionStatusLabelKey(run.status)
        return (
          <div
            key={`${run.kind}:${run.id}`}
            className="mt-2 flex gap-2 rounded-control border border-border px-2 py-1.5">
            <span className="flex h-5 shrink-0 items-center">
              <ExecutionStatusMark status={run.status} />
            </span>
            <div className="min-w-0 flex-1">
              <p className="line-clamp-2 break-words">{run.title}</p>
              <p className="flex flex-wrap items-center gap-x-1.5 text-xs text-fg-tertiary tabular-nums">
                <span>{[status && t(status), executionProgressLabel(run, t)].filter(Boolean).join(' · ')}</span>
                <RunningElapsed
                  createdAt={run.createdAt}
                  startedAt={run.startedAt}
                  completedAt={run.completedAt}
                  updatedAt={run.updatedAt}
                  status={run.status}
                />
              </p>
            </div>
          </div>
        )
      })}
      {(item.agent || stoppable) && (
        <div className="mt-2 flex min-h-6 items-center gap-2 text-xs text-fg-secondary">
          {item.agent && (
            <>
              <ChatAvatar name={item.agent.name} agent className="size-5" />
              <span className="min-w-0 flex-1 truncate">{item.agent.name}</span>
            </>
          )}
          {stoppable && (
            <Button
              size="xs"
              variant="ghost"
              className="ml-auto"
              disabled={stop.isPending}
              aria-label={`${t('pod.chat_timeline.execution_stop_action')} ${stoppable.title}`}
              onClick={() => stop.mutate(stoppable)}>
              <RiStopCircleLine aria-hidden />
              {t(stop.isPending ? 'pod.chat_timeline.execution_stopping' : 'pod.chat_timeline.execution_stop_action')}
            </Button>
          )}
        </div>
      )}
      <ContentError error={stop.error} />
    </article>
  )
}

function WorkList({ items, selected, open }: { items: WorkItem[]; selected: string | null; open: Open }) {
  const { t, i18n } = useTranslation()
  return (
    <ul className="grid gap-0.5">
      {items.map(item => (
        <li key={item.id}>
          <button
            type="button"
            aria-current={selected === item.id ? 'true' : undefined}
            className="flex min-h-9 w-full items-center gap-3 rounded-control px-3 py-1 text-left text-[13px] leading-5 hover:bg-accent focus-visible:bg-accent focus-visible:outline-2 focus-visible:outline-ring aria-[current=true]:bg-accent"
            onClick={event => open(item.id, event.currentTarget)}>
            <span className="min-w-0 flex-1 truncate">{item.title || t('pod.content.untitled')}</span>
            <span className="w-24 shrink-0 text-xs text-fg-secondary">{t(`pod.work.status.${item.status}`)}</span>
            <span className="hidden w-40 shrink-0 truncate text-xs text-fg-secondary md:block">{item.agent?.name}</span>
            <span className="hidden w-20 shrink-0 text-right text-xs text-fg-tertiary lg:block">
              {formatRelativeTime(item.lastActivityAt, i18n.language)}
            </span>
          </button>
        </li>
      ))}
    </ul>
  )
}

/** The recurring rules and pending checkbacks of the viewer's rooms. Each row opens the room that owns it. */
function ScheduledWork({ open }: { open: Open }) {
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
            <button
              type="button"
              className="flex min-h-9 w-full items-center gap-3 rounded-control px-3 py-1 text-left text-[13px] leading-5 hover:bg-accent focus-visible:bg-accent focus-visible:outline-2 focus-visible:outline-ring"
              onClick={event => open(row.conversationID, event.currentTarget)}>
              <span className="w-24 shrink-0 text-xs text-fg-tertiary">{t(`pod.work.schedule_kind.${row.kind}`)}</span>
              <span className="min-w-0 flex-1 truncate">
                {row.title || row.conversationTitle || t('pod.content.untitled')}
              </span>
              <span className="hidden w-40 shrink-0 truncate text-xs text-fg-secondary md:block">{row.agentName}</span>
              <span className="w-44 shrink-0 text-xs text-fg-secondary">
                {row.status === 'paused'
                  ? t('pod.work.paused')
                  : row.dueAt
                    ? t('pod.work.next_run', { time: formatDateTime(row.dueAt, i18n.language) })
                    : ''}
              </span>
            </button>
          </li>
        ))}
      </ul>
    </section>
  )
}
