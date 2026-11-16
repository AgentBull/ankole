import { Badge, Button, buttonVariants, Sheet, SheetContent, SheetTitle, Spinner, toast } from '@ankole/uikit'
import {
  CalendarClockRegular,
  CaretRightFilled,
  DeleteRegular,
  DismissCircleRegular,
  DismissRegular,
  OpenRegular,
  PauseCircleRegular,
  PlayCircleRegular,
  WarningRegular
} from '@ankole/uikit/icons'
import { useModel } from '@preact/signals-react'
import { useSignals } from '@preact/signals-react/runtime'
import { useMutation, useQuery, useQueryClient } from '@tanstack/react-query'
import { Link } from '@tanstack/react-router'
import {
  useEffect,
  useRef,
  useState,
  type ComponentProps,
  type CSSProperties,
  type KeyboardEvent as ReactKeyboardEvent,
  type PointerEvent as ReactPointerEvent,
  type ReactNode,
  type RefObject
} from 'react'
import { useTranslation } from 'react-i18next'
import { formatDateTime, formatRelativeTime } from '../common/date-time'
import { podLocation, podPagePath } from '../common/pod-url'
import { requestErrorMessage } from '../common/request-errors'
import { changePodJobRoutine } from './api/generated/sdk.gen'
import { ChatMarkdown } from './chat/chat-markdown'
import { ExecutionInspectorPanel } from './chat/execution-inspector-panel'
import { ExecutionStatusMark, executionStatusLabelKey, executionStatusTone } from './chat/execution-status'
import { ContentError } from './content-primitives'
import {
  jobRoutineQuery,
  jobsError,
  jobsKeys,
  type JobBoardItem,
  type JobCandidateAgent,
  type JobRoutineDetail,
  type JobRoutineKind
} from './jobs-api'
import { PodPanelSurface, popupOpen, type PanelInputEvent } from './panel-motion'
import {
  CHAT_COLUMN_MIN_WIDTH,
  CHAT_INSPECTOR_MIN_WIDTH,
  ChatInspectorLayoutModel
} from './state/chat-inspector-layout'
import './chat.css'

export type JobExecutionRef = {
  kind: 'background_agent_job' | 'workflow'
  id: string
}

type ParsedSelection =
  | { type: 'execution'; kind: 'background_agent_job' | 'workflow'; rawID: string }
  | { type: 'routine'; kind: JobRoutineKind; rawID: string }

function parseSelectedCard(id: string, item?: JobBoardItem): ParsedSelection | null {
  if (item) {
    if (item.cardType === 'one_off' && (item.kind === 'background_agent_job' || item.kind === 'workflow')) {
      return { type: 'execution', kind: item.kind, rawID: item.rawID }
    }
    if (
      item.cardType === 'routine' &&
      (item.kind === 'cron' || item.kind === 'automation_job' || item.kind === 'checkback')
    ) {
      return { type: 'routine', kind: item.kind, rawID: item.rawID }
    }
  }
  const colon = id.indexOf(':')
  if (colon <= 0) return null
  const prefix = id.slice(0, colon)
  const rawID = id.slice(colon + 1).trim()
  if (!rawID) return null
  if (prefix === 'job') return { type: 'execution', kind: 'background_agent_job', rawID }
  if (prefix === 'workflow') return { type: 'execution', kind: 'workflow', rawID }
  if (prefix === 'cron') return { type: 'routine', kind: 'cron', rawID }
  if (prefix === 'automation') return { type: 'routine', kind: 'automation_job', rawID }
  if (prefix === 'checkback') return { type: 'routine', kind: 'checkback', rawID }
  return null
}

export function JobsDetailPanel({
  id,
  run,
  item,
  agents,
  variant = 'panel',
  finalFocus,
  close,
  selectRun
}: {
  id: string
  run: JobExecutionRef | null
  item?: JobBoardItem
  agents: JobCandidateAgent[]
  variant?: 'panel' | 'sheet'
  finalFocus?: RefObject<HTMLElement | null>
  close: (event?: PanelInputEvent) => void
  selectRun: (next: JobExecutionRef | null) => void
}) {
  const { t } = useTranslation()
  const parsed = parseSelectedCard(id, item)

  useEffect(() => {
    if (variant !== 'panel') return
    const handleKeyDown = (event: KeyboardEvent) => {
      if (event.key !== 'Escape' || event.defaultPrevented || event.isComposing || popupOpen()) return
      const targetEl = event.target instanceof HTMLElement ? event.target : null
      if (targetEl?.closest('[role="dialog"], [role="menu"], [role="listbox"]')) return
      event.preventDefault()
      close()
    }
    window.addEventListener('keydown', handleKeyDown)
    return () => window.removeEventListener('keydown', handleKeyDown)
  }, [variant, close])

  const resolveAgentName = (uid: string) => agents.find(agent => agent.uid === uid)?.displayName

  const openChatAction = item?.conversationID ? (
    <Link
      to={podLocation(`/conversations/${item.conversationID}`).pathname}
      aria-label={t('pod.jobs.open_chat')}
      title={t('pod.jobs.open_chat')}
      className={buttonVariants({ variant: 'ghost', size: 'icon-sm' })}>
      <OpenRegular aria-hidden />
    </Link>
  ) : undefined

  const surfaceLabel = item?.title || t('pod.jobs.title')
  const executionTarget = run ?? (parsed?.type === 'execution' ? { kind: parsed.kind, id: parsed.rawID } : null)

  let body: ReactNode
  if (executionTarget) {
    const fromRoutine = parsed?.type === 'routine' && run !== null
    body = (
      <ExecutionInspectorPanel
        variant="inline"
        target={{
          type: 'execution',
          kind: executionTarget.kind,
          runID: executionTarget.id,
          title: item?.title || undefined,
          agentName: item?.agentName || undefined,
          fromSummary: fromRoutine
        }}
        resolveAgentName={resolveAgentName}
        actions={openChatAction}
        onClose={close}
        onBackToSummary={fromRoutine ? () => selectRun(null) : undefined}
        onSwitchTarget={next => {
          if (next.type !== 'execution') return
          if (parsed?.type === 'execution' && next.kind === parsed.kind && next.runID === parsed.rawID) {
            selectRun(null)
          } else {
            selectRun({ kind: next.kind, id: next.runID })
          }
        }}
      />
    )
  } else if (parsed?.type === 'routine') {
    body = (
      <RoutineInspectorContent
        kind={parsed.kind}
        rawID={parsed.rawID}
        fallbackItem={item}
        close={close}
        selectRun={selectRun}
      />
    )
  } else {
    body = (
      <div className="pod-chat-inspector-inner">
        <header className="pod-chat-inspector-header">
          <div className="pod-chat-inspector-title-row">
            <h2 className="pod-chat-inspector-title">{t('pod.jobs.title')}</h2>
            <Button
              type="button"
              size="icon-sm"
              variant="ghost"
              aria-label={t('common.close')}
              title={t('common.close')}
              onClick={event => close(event.nativeEvent)}>
              <DismissRegular aria-hidden />
            </Button>
          </div>
        </header>
        <div className="pod-chat-inspector-scroll">
          <div className="pod-chat-inspector-content">
            <p className="pod-chat-inspector-empty">{t('pod.jobs.errors.job_not_found')}</p>
          </div>
        </div>
      </div>
    )
  }

  if (variant === 'sheet') {
    return (
      <Sheet open onOpenChange={open => !open && close()}>
        <SheetContent
          className="pod-chat-inspector-sheet"
          showCloseButton={false}
          closeLabel={t('common.close')}
          finalFocus={finalFocus}>
          <SheetTitle className="sr-only">{surfaceLabel}</SheetTitle>
          {body}
        </SheetContent>
      </Sheet>
    )
  }

  return (
    <JobsSplitSurface
      aria-label={surfaceLabel}
      onKeyDown={event => {
        if (
          event.key === 'Escape' &&
          !event.defaultPrevented &&
          !event.nativeEvent.isComposing &&
          !popupOpen() &&
          !(event.target as HTMLElement).closest('[role="dialog"], [role="menu"], [role="listbox"]')
        ) {
          event.preventDefault()
          event.stopPropagation()
          close()
        }
      }}>
      {body}
    </JobsSplitSurface>
  )
}

function JobsSplitSurface({
  children,
  ...props
}: Omit<ComponentProps<typeof PodPanelSurface>, 'className' | 'children'> & { children: ReactNode }) {
  useSignals()
  const layout = useModel(ChatInspectorLayoutModel)
  return (
    <PodPanelSurface
      {...props}
      className="pod-chat-side-panel pod-chat-inspector-panel pod-chat-inspector-split"
      style={{ '--pod-chat-inspector-width': `${layout.width.value}px` } as CSSProperties}>
      <JobsInspectorResizeHandle layout={layout} />
      {children}
    </PodPanelSurface>
  )
}

function JobsInspectorResizeHandle({ layout }: { layout: InstanceType<typeof ChatInspectorLayoutModel> }) {
  useSignals()
  const { t } = useTranslation()
  const handle = useRef<HTMLDivElement>(null)
  const drag = useRef<{ pointerId: number; startX: number; startWidth: number } | null>(null)
  const [widest, setWidest] = useState<number>(CHAT_INSPECTOR_MIN_WIDTH)

  useEffect(() => {
    const room = handle.current?.closest<HTMLElement>('.pod-chat-room-body')
    if (!room) return
    const observer = new ResizeObserver(() =>
      setWidest(Math.max(CHAT_INSPECTOR_MIN_WIDTH, room.clientWidth - CHAT_COLUMN_MIN_WIDTH))
    )
    observer.observe(room)
    return () => observer.disconnect()
  }, [])

  useEffect(
    () => () => {
      if (drag.current) layout.commitWidth(layout.width.peek())
    },
    [layout]
  )

  const finishResize = (event: ReactPointerEvent<HTMLDivElement>) => {
    if (drag.current?.pointerId !== event.pointerId) return
    drag.current = null
    layout.commitWidth(layout.width.peek())
    delete event.currentTarget.dataset.resizing
    if (event.currentTarget.hasPointerCapture(event.pointerId)) {
      event.currentTarget.releasePointerCapture(event.pointerId)
    }
  }

  const resizeWithKeyboard = (event: ReactKeyboardEvent<HTMLDivElement>) => {
    let next: number
    switch (event.key) {
      case 'ArrowLeft':
        next = layout.width.peek() + 24
        break
      case 'ArrowRight':
        next = layout.width.peek() - 24
        break
      case 'Home':
        next = CHAT_INSPECTOR_MIN_WIDTH
        break
      case 'End':
        next = widest
        break
      default:
        return
    }
    event.preventDefault()
    layout.commitWidth(Math.min(next, widest))
  }

  const width = Math.min(layout.width.value, widest)

  return (
    <div
      ref={handle}
      role="separator"
      aria-label={t('pod.chat_timeline.execution_resize_panel')}
      aria-orientation="vertical"
      aria-valuemin={CHAT_INSPECTOR_MIN_WIDTH}
      aria-valuemax={widest}
      aria-valuenow={width}
      tabIndex={0}
      className="pod-chat-inspector-resize resize-edge"
      onKeyDown={resizeWithKeyboard}
      onPointerDown={event => {
        if (event.button !== 0) return
        event.preventDefault()
        event.currentTarget.focus({ preventScroll: true })
        event.currentTarget.setPointerCapture(event.pointerId)
        event.currentTarget.dataset.resizing = ''
        drag.current = { pointerId: event.pointerId, startX: event.clientX, startWidth: width }
      }}
      onPointerMove={event => {
        const current = drag.current
        if (current?.pointerId !== event.pointerId) return
        layout.previewWidth(Math.min(current.startWidth + current.startX - event.clientX, widest))
      }}
      onPointerUp={finishResize}
      onPointerCancel={finishResize}
      onLostPointerCapture={finishResize}
    />
  )
}

function RoutineInspectorContent({
  kind,
  rawID,
  fallbackItem,
  close,
  selectRun
}: {
  kind: JobRoutineKind
  rawID: string
  fallbackItem?: JobBoardItem
  close: (event?: PanelInputEvent) => void
  selectRun: (next: JobExecutionRef | null) => void
}) {
  const { t, i18n } = useTranslation()
  const client = useQueryClient()
  const routine = useQuery(jobRoutineQuery(kind, rawID))
  const detail: JobRoutineDetail | undefined = routine.data
  const item = detail?.item ?? fallbackItem

  const actionMutation = useMutation({
    mutationFn: (action: 'pause' | 'resume' | 'run' | 'remove' | 'cancel') => {
      if (kind !== 'cron' && kind !== 'checkback') {
        throw new Error('Unsupported routine action')
      }
      return changePodJobRoutine({
        path: { kind, raw_id: rawID },
        body: { data: { action } }
      })
    },
    onSuccess: (_result, action) => {
      void client.invalidateQueries({ queryKey: jobsKeys.all })
      if (action === 'remove' || action === 'cancel') {
        close()
      }
    },
    onError: error => {
      toast.error(requestErrorMessage(jobsError(error)))
    }
  })

  const title = item?.title || t(`pod.jobs.kinds.${kind}`)
  const status = item?.status ?? 'scheduled'
  const statusLabel = routineStatusLabel(status, t)

  return (
    <div className="pod-chat-inspector-inner" data-status={executionStatusTone(status)}>
      <header className="pod-chat-inspector-header">
        <div className="pod-chat-inspector-title-row">
          <CalendarClockRegular aria-hidden />
          <h2 className="pod-chat-inspector-title" title={title}>
            {title}
          </h2>
          {item?.conversationID && (
            <Link
              to={podLocation(`/conversations/${item.conversationID}`).pathname}
              aria-label={t('pod.jobs.open_chat')}
              title={t('pod.jobs.open_chat')}
              className={buttonVariants({ variant: 'ghost', size: 'icon-sm' })}>
              <OpenRegular aria-hidden />
            </Link>
          )}
          {item?.kind === 'automation_job' && item.pageID && (
            <Link
              to={podPagePath(item.pageID, item.pageTitle)}
              aria-label={t('pod.jobs.open_applet')}
              title={t('pod.jobs.open_applet')}
              className={buttonVariants({ variant: 'ghost', size: 'icon-sm' })}>
              <OpenRegular aria-hidden />
            </Link>
          )}
          <Button
            type="button"
            size="icon-sm"
            variant="ghost"
            aria-label={t('common.close')}
            title={t('common.close')}
            onClick={event => close(event.nativeEvent)}>
            <DismissRegular aria-hidden />
          </Button>
        </div>

        <div className="pod-chat-inspector-meta">
          <span>{t(`pod.jobs.kinds.${kind}`)}</span>
          <Badge variant={routineStatusBadgeVariant(status)} size="sm">
            {statusLabel}
          </Badge>
          {item?.agentName && <span>{item.agentName}</span>}
          {!item?.agentName && item?.pageTitle && <span>{item.pageTitle}</span>}
        </div>

        {item?.manageable && (kind === 'cron' || kind === 'checkback') && (
          <div className="flex flex-wrap items-center gap-1.5 pb-2">
            {kind === 'cron' && (
              <>
                <Button
                  type="button"
                  size="xs"
                  variant="outline"
                  disabled={actionMutation.isPending}
                  onClick={() => actionMutation.mutate('run')}>
                  <PlayCircleRegular aria-hidden />
                  {t('pod.jobs.action_run_now')}
                </Button>
                {item.status === 'paused' ? (
                  <Button
                    type="button"
                    size="xs"
                    variant="outline"
                    disabled={actionMutation.isPending}
                    onClick={() => actionMutation.mutate('resume')}>
                    <PlayCircleRegular aria-hidden />
                    {t('pod.jobs.action_resume')}
                  </Button>
                ) : (
                  <Button
                    type="button"
                    size="xs"
                    variant="outline"
                    disabled={actionMutation.isPending}
                    onClick={() => actionMutation.mutate('pause')}>
                    <PauseCircleRegular aria-hidden />
                    {t('pod.jobs.action_pause')}
                  </Button>
                )}
                <Button
                  type="button"
                  size="xs"
                  variant="ghost"
                  className="hover:bg-destructive/10 hover:text-destructive-fg"
                  disabled={actionMutation.isPending}
                  onClick={() => actionMutation.mutate('remove')}>
                  <DeleteRegular aria-hidden />
                  {t('pod.jobs.action_remove')}
                </Button>
              </>
            )}
            {kind === 'checkback' && (
              <Button
                type="button"
                size="xs"
                variant="outline"
                disabled={actionMutation.isPending}
                onClick={() => actionMutation.mutate('cancel')}>
                <DismissCircleRegular aria-hidden />
                {t('pod.jobs.action_cancel')}
              </Button>
            )}
          </div>
        )}
      </header>

      <div className="pod-chat-inspector-scroll">
        <div className="pod-chat-inspector-content">
          {routine.isPending && !detail ? (
            <div className="flex items-center justify-center py-8">
              <Spinner />
            </div>
          ) : routine.error ? (
            <ContentError error={jobsError(routine.error)} retry={() => void routine.refetch()} />
          ) : (
            <div className="grid gap-4">
              {detail?.unavailableReason && (
                <div role="alert" className="pod-chat-inspector-error">
                  <WarningRegular aria-hidden />
                  <p>{detail.unavailableReason}</p>
                </div>
              )}

              <section className="divide-y divide-border-subtle/60 rounded-surface border border-border-subtle/80 bg-layer-01/45 px-3 text-xs">
                {item?.triggerSummary && (
                  <div className="flex items-baseline justify-between gap-3 py-2.5">
                    <span className="text-fg-tertiary">{t('pod.jobs.field_schedule')}</span>
                    <span className="font-mono text-fg-primary">
                      {item.triggerSummary}
                      {item.timezone ? ` (${item.timezone})` : ''}
                    </span>
                  </div>
                )}
                {item?.nextRunAt && (
                  <div className="flex items-baseline justify-between gap-3 py-2.5">
                    <span className="text-fg-tertiary">{t('pod.jobs.next_run')}</span>
                    <span
                      className="text-fg-primary tabular-nums"
                      title={formatDateTime(item.nextRunAt, i18n.language)}>
                      {formatDateTime(item.nextRunAt, i18n.language)}
                    </span>
                  </div>
                )}
                {item?.lastRunAt && (
                  <div className="flex items-baseline justify-between gap-3 py-2.5">
                    <span className="text-fg-tertiary">{t('pod.jobs.last_run')}</span>
                    <span
                      className="text-fg-primary tabular-nums"
                      title={formatDateTime(item.lastRunAt, i18n.language)}>
                      {formatRelativeTime(item.lastRunAt, i18n.language)}
                    </span>
                  </div>
                )}
                {detail?.quietSuccess != null && (
                  <div className="flex items-center justify-between gap-3 py-2.5">
                    <span className="text-fg-tertiary">{t('pod.jobs.field_quiet_success')}</span>
                    <Badge variant="secondary" size="sm">
                      {detail.quietSuccess ? t('pod.jobs.enabled') : t('pod.jobs.disabled')}
                    </Badge>
                  </div>
                )}
              </section>

              {detail?.instructions ? (
                <section className="pod-chat-inspector-outcome [&_.pod-chat-markdown]:text-65 [&_.pod-chat-markdown]:leading-5">
                  <header>{t('pod.jobs.instructions')}</header>
                  <ChatMarkdown text={detail.instructions} />
                </section>
              ) : null}

              {detail && detail.childExecutions.length > 0 && (
                <section className="grid gap-1.5">
                  <h3 className="text-xs font-medium text-fg-tertiary">{t('pod.jobs.delegated_runs')}</h3>
                  <div className="grid gap-1.5">
                    {detail.childExecutions.map(exec => (
                      <button
                        key={`${exec.kind}:${exec.id}`}
                        type="button"
                        onClick={() => selectRun({ kind: exec.kind, id: exec.id })}
                        className="group/exec flex min-w-0 cursor-pointer flex-col gap-1 rounded-surface border border-border-subtle/80 bg-page px-3 py-2.5 text-start text-xs transition-[border-color,box-shadow] duration-(--duration-feedback) hover:border-control-edge hover:shadow-sm focus-visible:outline-2 focus-visible:outline-offset-2 focus-visible:outline-ring">
                        <div className="flex w-full min-w-0 items-center gap-2">
                          <span className="flex shrink-0 [&>svg]:size-3.5">
                            <ExecutionStatusMark status={exec.status} />
                          </span>
                          <span className="min-w-0 flex-1 truncate font-medium text-fg-primary">{exec.title}</span>
                          <span className="shrink-0 text-50 text-fg-tertiary tabular-nums">
                            {formatRelativeTime(exec.completedAt ?? exec.startedAt ?? exec.createdAt, i18n.language)}
                          </span>
                          <CaretRightFilled
                            aria-hidden
                            className="size-3 shrink-0 text-fg-tertiary transition-transform duration-(--duration-feedback) group-hover/exec:translate-x-0.5"
                          />
                        </div>
                        {exec.summary && <p className="line-clamp-1 ps-5.5 text-fg-secondary">{exec.summary}</p>}
                      </button>
                    ))}
                  </div>
                </section>
              )}

              <section className="grid gap-1.5">
                <h3 className="text-xs font-medium text-fg-tertiary">{t('pod.jobs.run_history')}</h3>
                {detail && detail.runs.length > 0 ? (
                  <div className="grid gap-1.5">
                    {detail.runs.map(entry => (
                      <div
                        key={entry.id}
                        className="grid gap-1.5 rounded-surface border border-border-subtle/80 bg-page px-3 py-2.5 text-xs">
                        <div className="flex items-center gap-2">
                          <span className="flex shrink-0 [&>svg]:size-3.5">
                            <ExecutionStatusMark status={entry.status} />
                          </span>
                          <span className="font-medium text-fg-primary">{routineStatusLabel(entry.status, t)}</span>
                          {entry.trigger && (
                            <span className="rounded-mini bg-layer-01 px-1.5 py-0.5 font-mono text-50 leading-3.5 text-fg-tertiary">
                              {entry.trigger}
                            </span>
                          )}
                          <span className="ms-auto shrink-0 text-50 text-fg-tertiary tabular-nums">
                            {formatRelativeTime(entry.finishedAt ?? entry.startedAt, i18n.language)}
                          </span>
                        </div>
                        {entry.error ? (
                          <p className="line-clamp-3 ps-5.5 text-destructive-fg">{entry.error}</p>
                        ) : entry.summary ? (
                          <p className="line-clamp-2 ps-5.5 text-fg-secondary">{entry.summary}</p>
                        ) : null}
                      </div>
                    ))}
                  </div>
                ) : (
                  <p className="pod-chat-inspector-empty">{t('pod.jobs.no_runs_yet')}</p>
                )}
              </section>
            </div>
          )}
        </div>
      </div>
    </div>
  )
}

function routineStatusBadgeVariant(status: string): 'info' | 'success' | 'warning' | 'destructive' | 'secondary' {
  switch (status) {
    case 'paused':
      return 'secondary'
    case 'unavailable':
    case 'failed':
      return 'destructive'
    case 'waiting_on_user':
      return 'warning'
    case 'running':
      return 'info'
    default:
      return 'success'
  }
}

function routineStatusLabel(status: string, t: (key: string) => string): string {
  switch (status) {
    case 'paused':
      return t('pod.jobs.status_paused')
    case 'scheduled':
    case 'active':
      return t('pod.jobs.status_scheduled')
    case 'unavailable':
      return t('pod.jobs.status_unavailable')
    default: {
      const key = executionStatusLabelKey(status)
      return key ? t(key) : status
    }
  }
}
