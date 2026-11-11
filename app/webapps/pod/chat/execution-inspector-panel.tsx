import { uuidV4 } from '@agentbull/active-support'
import { Button, Sheet, SheetContent, SheetTitle, useReducedMotion, Spinner } from '@ankole/uikit'
import {
  ArrowDownRegular,
  ArrowLeftRegular,
  ArrowRightRegular,
  ArrowUpRegular,
  CaretRightFilled,
  CircleRegular,
  DismissCircleRegular,
  DismissRegular,
  QuestionCircleRegular,
  RecordStopRegular,
  TextBulletListTreeRegular
} from '@ankole/uikit/icons'
import { useInfiniteQuery, useMutation, useQueryClient } from '@tanstack/react-query'
import { useEffect, useRef, useState, type ReactNode, type RefObject } from 'react'
import { useTranslation } from 'react-i18next'
import { useStickToBottom } from 'use-stick-to-bottom'
import { chatError, podKeys } from '../api'
import {
  conversationExecution,
  messageConversationExecution,
  stopConversationExecution
} from '../api/generated/sdk.gen'
import { ContentError } from '../content-primitives'
import { PodPanelSurface, popupOpen, type PanelInputEvent } from '../panel-motion'
import { refreshConversationQueries } from '../query-cache'
import { requestErrorMessage } from '../../common/request-errors'
import { ChatMarkdown } from './chat-markdown'
import {
  ExecutionStatusMark,
  RunningElapsed,
  executionStatusLabelKey,
  executionStatusTone,
  isLiveExecutionStatus
} from './execution-status'
import {
  buildNarrativeSegments,
  isStepActive,
  shouldShowOutcomeSummary,
  type NarrativeSegment,
  type WorkGroupSegment
} from './execution-narrative'
import { WorkingLabel } from './collapsed-work-view'
import { PeerExchangeInspectorBody } from './peer-exchange-card'
import { ToolRunView, formatToolDetail, localizedStepTitle } from './tool-run-view'
import type { ConversationExecutionDetail, ConversationExecutionItem, InspectorTarget } from './types'

export function ExecutionInspectorPanel({
  conversationID,
  target,
  variant = 'panel',
  finalFocus,
  resolveAgentName,
  onClose,
  onBackToSummary,
  onSwitchTarget,
  actions
}: {
  conversationID: string
  target: InspectorTarget
  /** `inline` renders only the inspector's content, inside a surface that the caller owns and closes. */
  variant?: 'panel' | 'sheet' | 'inline'
  finalFocus?: RefObject<HTMLElement | null>
  resolveAgentName?: (agentUID: string) => string | undefined
  onClose: (event?: PanelInputEvent) => void
  onBackToSummary?: (event?: PanelInputEvent) => void
  onSwitchTarget: (next: InspectorTarget) => void
  /** Controls that the opening surface adds to the header, before Close, such as the Work page's Issue step. */
  actions?: ReactNode
}) {
  const { t } = useTranslation()

  useEffect(() => {
    if (variant !== 'panel') return
    const handleKeyDown = (event: KeyboardEvent) => {
      if (event.key !== 'Escape' || event.defaultPrevented || event.isComposing || popupOpen()) return
      const targetEl = event.target instanceof HTMLElement ? event.target : null
      if (targetEl?.closest('[role="dialog"], [role="menu"], [role="listbox"], .pod-chat-find')) return
      event.preventDefault()
      onClose()
    }
    window.addEventListener('keydown', handleKeyDown)
    return () => window.removeEventListener('keydown', handleKeyDown)
  }, [variant, onClose])

  const body = (
    <InspectorContent
      conversationID={conversationID}
      target={target}
      resolveAgentName={resolveAgentName}
      onClose={onClose}
      onBackToSummary={target.fromSummary ? onBackToSummary : undefined}
      onSwitchTarget={onSwitchTarget}
      actions={actions}
    />
  )

  const surfaceLabel =
    target.type === 'peer'
      ? t('pod.superagent.exchange_with', {
          name: resolveAgentName?.(target.agentUID) ?? `@${target.agentUID}`
        })
      : target.title || t('pod.chat_timeline.background_work')

  if (variant === 'inline') return body

  if (variant === 'sheet') {
    return (
      <Sheet open onOpenChange={open => !open && onClose()}>
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
    <PodPanelSurface
      aria-label={surfaceLabel}
      className="pod-chat-side-panel pod-chat-inspector-panel"
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
          onClose()
        }
      }}>
      {body}
    </PodPanelSurface>
  )
}

function InspectorContent({
  conversationID,
  target,
  resolveAgentName,
  onClose,
  onBackToSummary,
  onSwitchTarget,
  actions
}: {
  conversationID: string
  target: InspectorTarget
  resolveAgentName?: (agentUID: string) => string | undefined
  onClose: (event?: PanelInputEvent) => void
  onBackToSummary?: (event?: PanelInputEvent) => void
  onSwitchTarget: (next: InspectorTarget) => void
  actions?: ReactNode
}) {
  const { t } = useTranslation()
  if (target.type === 'peer') {
    const peerTitle = t('pod.superagent.exchange_with', {
      name: resolveAgentName?.(target.agentUID) ?? `@${target.agentUID}`
    })
    return (
      <div className="pod-chat-inspector-inner">
        <header className="pod-chat-inspector-header">
          <div className="pod-chat-inspector-title-row">
            {onBackToSummary && (
              <Button
                size="icon-sm"
                variant="ghost"
                aria-label={t('pod.chat_room.summary')}
                onClick={event => onBackToSummary(event.nativeEvent)}>
                <ArrowLeftRegular aria-hidden />
              </Button>
            )}
            <h2 className="pod-chat-inspector-title" title={peerTitle}>
              {peerTitle}
            </h2>
            <Button
              size="icon-sm"
              variant="ghost"
              aria-label={t('common.close')}
              onClick={event => onClose(event.nativeEvent)}>
              <DismissRegular aria-hidden />
            </Button>
          </div>
        </header>
        <div className="pod-chat-inspector-scroll">
          <div className="pod-chat-inspector-content">
            <PeerExchangeInspectorBody
              conversationID={conversationID}
              exchangeID={target.exchangeID}
              agentUID={target.agentUID}
            />
          </div>
        </div>
      </div>
    )
  }

  return (
    <ExecutionInspectorBody
      key={`${target.kind}:${target.runID}`}
      conversationID={conversationID}
      target={target}
      resolveAgentName={resolveAgentName}
      onClose={onClose}
      onBackToSummary={onBackToSummary}
      onSwitchTarget={onSwitchTarget}
      actions={actions}
    />
  )
}

function ExecutionInspectorBody({
  conversationID,
  target,
  resolveAgentName,
  onClose,
  onBackToSummary,
  onSwitchTarget,
  actions
}: {
  conversationID: string
  target: Extract<InspectorTarget, { type: 'execution' }>
  resolveAgentName?: (agentUID: string) => string | undefined
  onClose: (event?: PanelInputEvent) => void
  onBackToSummary?: (event?: PanelInputEvent) => void
  onSwitchTarget: (next: InspectorTarget) => void
  actions?: ReactNode
}) {
  const { t } = useTranslation()
  const client = useQueryClient()
  const reducedMotion = useReducedMotion()
  const [selectedThreadID, setSelectedThreadID] = useState<string | null>(null)
  const [taskExpanded, setTaskExpanded] = useState(false)
  const [draft, setDraft] = useState('')
  const [selectedChoices, setSelectedChoices] = useState<Record<string, string>>({})
  const textareaRef = useRef<HTMLTextAreaElement>(null)

  const query = useInfiniteQuery({
    queryKey: [...podKeys.detail(conversationID), 'execution', target.kind, target.runID],
    initialPageParam: null as string | null,
    queryFn: ({ pageParam, signal }) =>
      conversationExecution({
        path: { id: conversationID, kind: target.kind, run_id: Number(target.runID) },
        query: { cursor: pageParam ?? undefined },
        signal
      }),
    getNextPageParam: page => page.nextCursor ?? undefined,
    retry: false,
    refetchInterval: q => {
      if (q.state.error) return false
      const status = q.state.data?.pages[0]?.status ?? target.initialRun?.status
      return isLiveExecutionStatus(status) ? 4000 : false
    }
  })

  const head: ConversationExecutionDetail | undefined = query.data?.pages[0]
  const status = head?.status ?? target.initialRun?.status ?? 'running'
  const title = head?.title ?? target.initialRun?.title ?? target.title ?? t('pod.chat_timeline.background_work')
  const agentUID = head?.agentUID ?? target.initialRun?.agentUID
  const agentName = (agentUID && resolveAgentName?.(agentUID)) || target.agentName || target.initialRun?.agentName
  const stoppable = head?.stoppable ?? Boolean(target.initialRun?.stoppable)
  const canMessage = head?.canMessage ?? Boolean(target.initialRun?.canMessage)
  const isLive = isLiveExecutionStatus(status)

  const stick = useStickToBottom({
    initial: 'instant',
    resize: reducedMotion ? 'instant' : 'smooth'
  })

  const stopMutation = useMutation({
    mutationFn: () =>
      stopConversationExecution({
        path: { id: conversationID, kind: target.kind, run_id: Number(target.runID) }
      }),
    onSuccess: () => {
      refreshConversationQueries(client, conversationID)
    }
  })

  const sendMutation = useMutation({
    mutationFn: (text: string) =>
      messageConversationExecution({
        path: { id: conversationID, run_id: Number(target.runID) },
        body: { data: { requestID: uuidV4(), text } }
      }),
    onSuccess: result => {
      setDraft('')
      setSelectedChoices({})
      refreshConversationQueries(client, conversationID)
      if (result.respawned && result.runID && result.runID !== target.runID) {
        onSwitchTarget({
          type: 'execution',
          kind: 'background_agent_job',
          runID: result.runID,
          title,
          agentName,
          fromSummary: target.fromSummary
        })
      }
    }
  })

  useEffect(() => {
    const el = textareaRef.current
    if (!el) return
    el.style.height = 'auto'
    el.style.height = `${Math.min(el.scrollHeight, 140)}px`
  }, [draft])

  const orderedPages =
    target.kind === 'background_agent_job' ? [...(query.data?.pages ?? [])].reverse() : (query.data?.pages ?? [])
  const allItems = orderedPages.flatMap(page => page.items)

  const threads = head?.threads ?? []
  const leadThread = threads.find(thread => thread.isLead) ?? threads[0]
  const activeThreadID =
    selectedThreadID && threads.some(thread => thread.id === selectedThreadID)
      ? selectedThreadID
      : (leadThread?.id ?? null)

  const visibleItems =
    threads.length <= 1 || !activeThreadID
      ? allItems
      : activeThreadID === leadThread?.id
        ? allItems.filter(item => !item.threadID || item.threadID === activeThreadID || item.isLead !== false)
        : allItems.filter(item => item.threadID === activeThreadID)

  const isJob = target.kind === 'background_agent_job'
  const onLeadThread = !isJob || activeThreadID === (leadThread?.id ?? null)
  const segments = isJob ? buildNarrativeSegments(visibleItems, isLive) : []
  const showOutcome = onLeadThread && shouldShowOutcomeSummary(head?.outcomeText, isJob ? visibleItems : [])

  const statusKey = executionStatusLabelKey(status)
  const statusLabel = statusKey ? t(statusKey) : status
  const createdAt = head?.createdAt ?? target.initialRun?.createdAt
  const startedAt = head?.startedAt ?? target.initialRun?.startedAt
  const completedAt = head?.completedAt ?? target.initialRun?.completedAt
  const updatedAt = head?.updatedAt ?? target.initialRun?.updatedAt
  const stepCount = head?.stepCount ?? target.initialRun?.stepCount ?? 0

  const taskText = head?.task?.trim()
  const taskIsLong = Boolean(taskText && (taskText.length > 180 || taskText.split('\n').length > 3))

  const submitText = (raw: string) => {
    const text = raw.trim()
    if (!text || sendMutation.isPending) return
    sendMutation.mutate(text)
  }

  const placeholder =
    status === 'waiting_on_user'
      ? t('pod.chat_timeline.execution_answer_placeholder')
      : isLive
        ? t('pod.chat_timeline.execution_steer_placeholder')
        : t('pod.chat_timeline.execution_followup_placeholder')

  const childThreads = threads.filter(thread => !thread.isLead)

  return (
    <div className="pod-chat-inspector-inner" data-status={executionStatusTone(status)}>
      <header className="pod-chat-inspector-header">
        <div className="pod-chat-inspector-title-row">
          {onBackToSummary && (
            <Button
              size="icon-sm"
              variant="ghost"
              aria-label={t('pod.chat_room.summary')}
              onClick={event => onBackToSummary(event.nativeEvent)}>
              <ArrowLeftRegular aria-hidden />
            </Button>
          )}
          <ExecutionStatusMark status={status} />
          <h2 className="pod-chat-inspector-title" title={title}>
            {title}
          </h2>
          {stoppable && (
            <Button size="xs" variant="ghost" disabled={stopMutation.isPending} onClick={() => stopMutation.mutate()}>
              <RecordStopRegular aria-hidden />
              {t(
                stopMutation.isPending
                  ? 'pod.chat_timeline.execution_stopping'
                  : 'pod.chat_timeline.execution_stop_action'
              )}
            </Button>
          )}
          {actions}
          <Button
            size="icon-sm"
            variant="ghost"
            aria-label={t('common.close')}
            onClick={event => onClose(event.nativeEvent)}>
            <DismissRegular aria-hidden />
          </Button>
        </div>
        <div className="pod-chat-inspector-meta">
          {agentName && <span>{agentName}</span>}
          <span className="pod-chat-inspector-status-text">{statusLabel}</span>
          {createdAt && (
            <RunningElapsed
              createdAt={createdAt}
              startedAt={startedAt}
              completedAt={completedAt}
              updatedAt={updatedAt}
              status={status}
            />
          )}
          {target.kind === 'workflow' && head?.workflowCounts && head.workflowCounts.total > 0 ? (
            <span>
              {t('pod.chat_timeline.execution_workflow_counts', {
                completed: head.workflowCounts.completed,
                total: head.workflowCounts.total
              })}
            </span>
          ) : stepCount > 0 ? (
            <span>{t('pod.chat_timeline.execution_steps_count', { count: stepCount })}</span>
          ) : null}
        </div>
        {(head?.continuedFromJobID || head?.successorJobID) && (
          <div className="pod-chat-inspector-chain">
            {head.continuedFromJobID && (
              <div className="pod-chat-inspector-chain-row">
                <span>{t('pod.chat_timeline.execution_continued_from')}</span>
                <Button
                  size="xs"
                  variant="ghost"
                  onClick={() =>
                    onSwitchTarget({
                      type: 'execution',
                      kind: 'background_agent_job',
                      runID: head.continuedFromJobID!,
                      agentName,
                      fromSummary: target.fromSummary
                    })
                  }>
                  <ArrowLeftRegular aria-hidden />
                  {t('pod.chat_timeline.execution_view_previous')}
                </Button>
              </div>
            )}
            {head.successorJobID && (
              <div className="pod-chat-inspector-chain-row" data-followup="">
                <span>{t('pod.chat_timeline.execution_continued_banner')}</span>
                <Button
                  size="xs"
                  variant="outline"
                  onClick={() =>
                    onSwitchTarget({
                      type: 'execution',
                      kind: 'background_agent_job',
                      runID: head.successorJobID!,
                      agentName,
                      fromSummary: target.fromSummary
                    })
                  }>
                  {t('pod.chat_timeline.execution_open_followup')}
                  <ArrowRightRegular aria-hidden />
                </Button>
              </div>
            )}
          </div>
        )}
        {threads.length > 1 && (
          <div className="pod-chat-inspector-threads" role="tablist" aria-label={t('pod.chat_timeline.agent')}>
            {leadThread && (
              <button
                type="button"
                role="tab"
                aria-selected={activeThreadID === leadThread.id}
                className="pod-chat-inspector-thread-pill"
                onClick={() => setSelectedThreadID(leadThread.id)}>
                {leadThread.status === 'running' && <Spinner aria-hidden className="pod-chat-working-spinner" />}
                <span>{t('pod.chat_timeline.execution_lead_thread')}</span>
              </button>
            )}
            {childThreads.map((thread, index) => (
              <button
                key={thread.id}
                type="button"
                role="tab"
                aria-selected={activeThreadID === thread.id}
                className="pod-chat-inspector-thread-pill"
                onClick={() => setSelectedThreadID(thread.id)}>
                {thread.status === 'running' ? (
                  <Spinner aria-hidden className="pod-chat-working-spinner" />
                ) : (
                  <TextBulletListTreeRegular aria-hidden />
                )}
                <span>{t('pod.chat_timeline.execution_child_thread', { index: index + 1 })}</span>
              </button>
            ))}
          </div>
        )}
      </header>

      <div ref={stick.scrollRef} className="pod-chat-inspector-scroll">
        <div ref={stick.contentRef} className="pod-chat-inspector-content">
          {isJob ? (
            <JobExecutionContent
              taskText={onLeadThread ? taskText : undefined}
              taskIsLong={taskIsLong}
              taskExpanded={taskExpanded}
              onToggleTask={() => setTaskExpanded(current => !current)}
              plan={onLeadThread && head?.plan && head.plan.steps.length > 0 ? head.plan : undefined}
              hasEarlier={Boolean(query.hasNextPage)}
              fetchingEarlier={query.isFetchingNextPage}
              onFetchEarlier={() => void query.fetchNextPage()}
              isPending={query.isPending}
              isLive={isLive}
              segments={segments}
              childThreads={childThreads}
              onSelectThread={setSelectedThreadID}
              pendingQuestions={
                status === 'waiting_on_user' && head?.pendingQuestions && head.pendingQuestions.length > 0
                  ? head.pendingQuestions
                  : undefined
              }
              selectedChoices={selectedChoices}
              onSelectChoice={(questionID, label) => {
                if (head?.pendingQuestions.length === 1) {
                  submitText(label)
                } else {
                  setSelectedChoices(prev => ({ ...prev, [questionID]: label }))
                }
              }}
              onSubmitSelected={() => {
                const lines = (head?.pendingQuestions ?? [])
                  .map(q => {
                    const value = selectedChoices[q.id]
                    return value ? `${q.header || q.question}: ${value}` : null
                  })
                  .filter((line): line is string => Boolean(line))
                if (lines.length > 0) submitText(lines.join('\n'))
              }}
              submittingAnswer={sendMutation.isPending}
            />
          ) : (
            <>
              {query.isPending && (
                <p role="status" className="pod-chat-inspector-empty">
                  <Spinner aria-hidden className="pod-chat-working-spinner" />
                  <span>{t('pod.chat_timeline.loading_execution')}</span>
                </p>
              )}
              <WorkflowInspectorStream
                items={visibleItems}
                counts={head?.workflowCounts ?? undefined}
                hasMore={Boolean(query.hasNextPage)}
                fetchingMore={query.isFetchingNextPage}
                onFetchMore={() => void query.fetchNextPage()}
              />
            </>
          )}

          {!query.isPending &&
            !query.error &&
            visibleItems.length === 0 &&
            !showOutcome &&
            !head?.errorText &&
            !(isJob && status === 'waiting_on_user' && head?.pendingQuestions.length) && (
              <p className="pod-chat-inspector-empty">
                {isLive && <Spinner aria-hidden className="pod-chat-working-spinner" />}
                <span>{t(isLive ? 'pod.chat_timeline.thinking' : 'pod.chat_timeline.no_execution_steps')}</span>
              </p>
            )}

          {head?.errorText && (
            <div role="alert" className="pod-chat-inspector-error">
              <DismissCircleRegular aria-hidden />
              <p>{head.errorText}</p>
            </div>
          )}

          {showOutcome && head?.outcomeText && (
            <section className="pod-chat-inspector-outcome">
              <header>{t('pod.chat_timeline.execution_outcome_heading')}</header>
              <ChatMarkdown text={head.outcomeText} generated />
            </section>
          )}

          <ContentError error={query.error || stopMutation.error} retry={() => void query.refetch()} />
        </div>
        {!stick.isAtBottom && (
          <Button
            className="pod-chat-jump-latest"
            variant="ghost"
            size="xs"
            onClick={() => void stick.scrollToBottom(reducedMotion ? 'instant' : undefined)}>
            <ArrowDownRegular aria-hidden />
            {t('pod.chat.scroll_latest')}
          </Button>
        )}
      </div>

      {target.kind === 'background_agent_job' && canMessage && (
        <footer className="pod-chat-inspector-composer">
          <JobQuickReplyComposer
            value={draft}
            onChange={setDraft}
            onSubmit={submitText}
            placeholder={placeholder}
            submitting={sendMutation.isPending}
            error={sendMutation.error ? requestErrorMessage(chatError(sendMutation.error)) : undefined}
            textareaRef={textareaRef}
          />
        </footer>
      )}
    </div>
  )
}

export function JobQuickReplyComposer({
  value,
  onChange,
  onSubmit,
  placeholder,
  submitting,
  error,
  textareaRef
}: {
  value: string
  onChange: (value: string) => void
  onSubmit: (text: string) => void
  placeholder: string
  submitting: boolean
  error?: string
  textareaRef?: RefObject<HTMLTextAreaElement | null>
}) {
  const { t } = useTranslation()
  return (
    <>
      {error && (
        <p role="alert" className="pod-chat-inspector-composer-error">
          {error}
        </p>
      )}
      <form
        className="pod-chat-inspector-composer-box"
        onSubmit={event => {
          event.preventDefault()
          onSubmit(value)
        }}>
        <textarea
          ref={textareaRef}
          rows={1}
          value={value}
          placeholder={placeholder}
          aria-label={placeholder}
          disabled={submitting}
          onChange={event => onChange(event.target.value)}
          onKeyDown={event => {
            if (event.key === 'Enter' && !event.shiftKey && !(event.nativeEvent.isComposing || event.keyCode === 229)) {
              event.preventDefault()
              onSubmit(value)
            }
          }}
        />
        <Button
          type="submit"
          size="icon-xs"
          variant="default"
          disabled={!value.trim() || submitting}
          aria-label={t('pod.chat_timeline.execution_send_action')}>
          <ArrowUpRegular aria-hidden />
        </Button>
      </form>
    </>
  )
}

function InspectorWorkGroup({
  segment,
  childThreads,
  onSelectThread
}: {
  segment: WorkGroupSegment
  childThreads: Array<{ id: string; isLead: boolean; status: string; turnCount: number }>
  onSelectThread: (threadID: string) => void
}) {
  const { t } = useTranslation()
  const [open, setOpen] = useState(segment.defaultOpen)
  const userToggled = useRef(false)

  useEffect(() => {
    if (!userToggled.current) {
      setOpen(segment.defaultOpen)
    }
  }, [segment.defaultOpen])

  const runningSteps = segment.steps.filter(isStepActive)
  const currentStep = runningSteps.at(-1)
  const failed = segment.steps.some(step => ['failed', 'error'].includes(step.status))
  const reasoningText = segment.reasoning.join('\n\n')
  const thinkingOnly = segment.steps.length === 0 && Boolean(reasoningText)

  const summaryLabel = currentStep
    ? localizedStepTitle(currentStep, t)
    : thinkingOnly
      ? t('pod.chat_timeline.thinking')
      : t('pod.chat_timeline.execution_actions_summary', { count: segment.steps.length })

  const matchingSubthreads = segment.spawnedThreadIDs
    .map(id => {
      const idx = childThreads.findIndex(thread => thread.id === id)
      return idx >= 0 ? { id, index: idx + 1, status: childThreads[idx]!.status } : null
    })
    .filter((entry): entry is { id: string; index: number; status: string } => Boolean(entry))

  return (
    <details
      className="pod-chat-work pod-chat-inspector-work-group"
      data-outcome={failed ? 'failed' : undefined}
      open={open}
      onToggle={event => {
        if (event.currentTarget.open !== open) {
          userToggled.current = true
          setOpen(event.currentTarget.open)
        }
      }}>
      <summary>
        <CaretRightFilled aria-hidden className="pod-chat-disclosure-caret" />
        {Boolean(currentStep) && <Spinner aria-hidden className="pod-chat-working-spinner" />}
        {currentStep ? <WorkingLabel text={summaryLabel} /> : <span>{summaryLabel}</span>}
        {currentStep && segment.steps.length > 1 && (
          <span className="text-fg-tertiary">
            {' '}
            · {t('pod.chat_timeline.execution_steps_count', { count: segment.steps.length })}
          </span>
        )}
      </summary>
      {open && (
        <div className="pod-chat-work-content">
          {reasoningText &&
            (thinkingOnly ? (
              <div className="pod-chat-thinking-text">{reasoningText}</div>
            ) : (
              <details className="pod-chat-thinking">
                <summary>
                  <CaretRightFilled aria-hidden className="pod-chat-disclosure-caret" />
                  {t('pod.chat_timeline.thinking')}
                </summary>
                <div className="whitespace-pre-wrap">{reasoningText}</div>
              </details>
            ))}
          <ToolRunView steps={segment.steps} live={Boolean(currentStep)} />
          {matchingSubthreads.length > 0 && (
            <div className="pod-chat-inspector-subthread-links">
              {matchingSubthreads.map(sub => (
                <Button key={sub.id} size="xs" variant="outline" onClick={() => onSelectThread(sub.id)}>
                  <TextBulletListTreeRegular aria-hidden />
                  {t('pod.chat_timeline.execution_child_thread', { index: sub.index })}
                </Button>
              ))}
            </div>
          )}
        </div>
      )}
    </details>
  )
}

function PlanCard({ plan }: { plan: NonNullable<ConversationExecutionDetail['plan']> }) {
  const { t } = useTranslation()
  const completed = plan.steps.filter(item => item.status === 'completed').length
  return (
    <section className="pod-chat-inspector-plan">
      <header>
        <span>{t('pod.chat_timeline.execution_plan_heading')}</span>
        <span className="tabular-nums">
          {completed}/{plan.steps.length}
        </span>
      </header>
      {plan.explanation && <p className="pod-chat-inspector-plan-note">{plan.explanation}</p>}
      <ol>
        {plan.steps.map((item, index) => {
          const done = item.status === 'completed'
          const active = item.status === 'in_progress'
          return (
            <li key={index} data-status={item.status}>
              <span className="pod-chat-tool-state">
                {done || active ? (
                  <ExecutionStatusMark status={done ? 'completed' : 'running'} />
                ) : (
                  <CircleRegular className="pod-chat-inspector-plan-pending" aria-hidden />
                )}
              </span>
              <span>{item.step}</span>
            </li>
          )
        })}
      </ol>
    </section>
  )
}

export function PendingQuestionsCard({
  questions,
  selectedChoices,
  onSelectChoice,
  onSubmitSelected,
  submitting
}: {
  questions: ConversationExecutionDetail['pendingQuestions']
  selectedChoices: Record<string, string>
  onSelectChoice: (questionID: string, label: string) => void
  onSubmitSelected: () => void
  submitting: boolean
}) {
  const { t } = useTranslation()
  const multi = questions.length > 1
  const hasSelection = Object.keys(selectedChoices).length > 0
  return (
    <section className="pod-chat-choice-card" data-state="pending">
      <div className="pod-chat-choice-header">
        <QuestionCircleRegular aria-hidden />
        <span>{t('pod.chat_timeline.decision_needed')}</span>
      </div>
      {questions.map(question => (
        <div key={question.id} className="pod-chat-inspector-question">
          <p className="pod-chat-choice-question">
            {question.header ? <strong>{question.header}: </strong> : null}
            {question.question}
          </p>
          {question.options && question.options.length > 0 && (
            <div className="pod-chat-choices">
              {question.options.map(option => {
                const pressed = selectedChoices[question.id] === option.label
                return (
                  <Button
                    key={option.label}
                    type="button"
                    variant="ghost"
                    className="pod-chat-choice"
                    aria-pressed={pressed}
                    disabled={submitting}
                    onClick={() => onSelectChoice(question.id, option.label)}>
                    <span>
                      <strong>{option.label}</strong>
                      {option.description && <small>{option.description}</small>}
                    </span>
                  </Button>
                )
              })}
            </div>
          )}
        </div>
      ))}
      {multi && hasSelection && (
        <div>
          <Button size="sm" disabled={submitting} onClick={onSubmitSelected}>
            {t(submitting ? 'pod.chat_timeline.submitting_answer' : 'pod.chat_timeline.answer')}
          </Button>
        </div>
      )}
    </section>
  )
}

function JobExecutionContent({
  taskText,
  taskIsLong,
  taskExpanded,
  onToggleTask,
  plan,
  hasEarlier,
  fetchingEarlier,
  onFetchEarlier,
  isPending,
  isLive,
  segments,
  childThreads,
  onSelectThread,
  pendingQuestions,
  selectedChoices,
  onSelectChoice,
  onSubmitSelected,
  submittingAnswer
}: {
  taskText?: string
  taskIsLong: boolean
  taskExpanded: boolean
  onToggleTask: () => void
  plan?: NonNullable<ConversationExecutionDetail['plan']>
  hasEarlier: boolean
  fetchingEarlier: boolean
  onFetchEarlier: () => void
  isPending: boolean
  isLive: boolean
  segments: NarrativeSegment[]
  childThreads: Array<{ id: string; isLead: boolean; status: string; turnCount: number }>
  onSelectThread: (threadID: string) => void
  pendingQuestions?: ConversationExecutionDetail['pendingQuestions']
  selectedChoices: Record<string, string>
  onSelectChoice: (questionID: string, label: string) => void
  onSubmitSelected: () => void
  submittingAnswer: boolean
}) {
  const { t } = useTranslation()
  return (
    <>
      {taskText && (
        <section className="pod-chat-inspector-brief">
          <header>
            <span>{t('pod.chat_timeline.execution_task_brief')}</span>
            {taskIsLong && (
              <button type="button" className="pod-chat-inspector-brief-toggle" onClick={onToggleTask}>
                {t(taskExpanded ? 'pod.chat_timeline.execution_show_less' : 'pod.chat_timeline.execution_show_more')}
              </button>
            )}
          </header>
          <p data-clamped={taskIsLong && !taskExpanded ? '' : undefined}>{taskText}</p>
        </section>
      )}

      {plan && <PlanCard plan={plan} />}

      {hasEarlier && (
        <div className="pod-chat-inspector-more">
          <Button
            variant="outline"
            size="xs"
            disabled={fetchingEarlier}
            aria-busy={fetchingEarlier}
            onClick={onFetchEarlier}>
            {t(fetchingEarlier ? 'pod.chat_timeline.loading_execution' : 'pod.chat_timeline.load_earlier_execution')}
          </Button>
        </div>
      )}

      {isPending && (
        <p role="status" className="pod-chat-inspector-empty">
          <Spinner aria-hidden className="pod-chat-working-spinner" />
          <span>{t('pod.chat_timeline.loading_execution')}</span>
        </p>
      )}

      <div className="pod-chat-inspector-stream">
        {segments.map((segment, index) => {
          if (segment.kind === 'steer') {
            return (
              <div key={segment.id} className="pod-chat-inspector-steer">
                <div className="pod-chat-human-text">
                  <ChatMarkdown text={segment.text} />
                </div>
              </div>
            )
          }
          if (segment.kind === 'message') {
            const streaming = isLive && index === segments.length - 1
            return (
              <div key={segment.id} className="pod-chat-inspector-prose">
                <ChatMarkdown text={segment.text} generated streaming={streaming} />
              </div>
            )
          }
          return (
            <InspectorWorkGroup
              key={segment.id}
              segment={segment}
              childThreads={childThreads}
              onSelectThread={onSelectThread}
            />
          )
        })}
      </div>

      {pendingQuestions && (
        <PendingQuestionsCard
          questions={pendingQuestions}
          selectedChoices={selectedChoices}
          onSelectChoice={onSelectChoice}
          onSubmitSelected={onSubmitSelected}
          submitting={submittingAnswer}
        />
      )}
    </>
  )
}

function WorkflowInspectorStream({
  items,
  counts,
  hasMore,
  fetchingMore,
  onFetchMore
}: {
  items: ConversationExecutionItem[]
  counts?: NonNullable<ConversationExecutionDetail['workflowCounts']>
  hasMore: boolean
  fetchingMore: boolean
  onFetchMore: () => void
}) {
  const { t } = useTranslation()
  const pct = counts && counts.total > 0 ? Math.round((counts.completed / counts.total) * 100) : 0
  return (
    <div className="pod-chat-inspector-workflow">
      {counts && counts.total > 0 && (
        <div className="pod-chat-inspector-workflow-summary">
          <div className="pod-chat-workflow-bar" aria-hidden>
            <span style={{ width: `${pct}%` }} data-failed={counts.failed > 0 || undefined} />
          </div>
          <div className="pod-chat-inspector-workflow-pills">
            <span>
              {t('pod.chat_timeline.execution_workflow_counts', {
                completed: counts.completed,
                total: counts.total
              })}
            </span>
            {counts.running > 0 && (
              <span>
                {t('pod.chat_timeline.running')} {counts.running}
              </span>
            )}
            {counts.sleeping > 0 && (
              <span>
                {t('pod.chat_timeline.execution_sleeping')} {counts.sleeping}
              </span>
            )}
            {counts.failed > 0 && (
              <span data-tone="failed">
                {t('pod.chat_timeline.failed')} {counts.failed}
              </span>
            )}
          </div>
        </div>
      )}
      <ol className="pod-chat-tool-run">
        {items.map(item => {
          const status = item.status || 'completed'
          const failed = status === 'failed'
          const sleeping = status === 'sleeping'
          const complete = status === 'completed' || status === 'succeeded'
          const output = formatToolDetail(item.output)
          const error = formatToolDetail(item.error)
          const expandable = Boolean(output || error || item.sleepNote)
          const Row = expandable ? 'details' : 'div'
          const Label = expandable ? 'summary' : 'div'
          const title = item.title || `${t('pod.chat_timeline.workflow')} #${item.callSeq ?? ''}`
          return (
            <li key={item.id}>
              <Row
                className="pod-chat-tool-step"
                data-status={failed ? 'failed' : complete ? 'completed' : 'running'}
                open={failed || undefined}>
                <Label className="pod-chat-tool-line">
                  {item.callSeq != null && <span className="pod-chat-workflow-seq">#{item.callSeq}</span>}
                  <span className="pod-chat-tool-title" title={title}>
                    {title}
                  </span>
                  {item.attempts != null && item.attempts > 1 && (
                    <span className="pod-chat-workflow-attempts">×{item.attempts}</span>
                  )}
                  <span className="pod-chat-tool-state">
                    <ExecutionStatusMark
                      status={failed ? 'failed' : sleeping ? 'sleeping' : complete ? 'completed' : 'running'}
                    />
                  </span>
                </Label>
                {expandable && (
                  <div className="pod-chat-block-card pod-chat-tool-detail">
                    {item.sleepNote && (
                      <div>
                        <span>{t('pod.chat_timeline.execution_sleeping')}</span>
                        <pre>{item.sleepNote}</pre>
                      </div>
                    )}
                    {error && (
                      <div data-tone="failed">
                        <span>{t('pod.chat_timeline.failed')}</span>
                        <pre>{error}</pre>
                      </div>
                    )}
                    {output && (
                      <div>
                        <span>{t('pod.chat_timeline.output')}</span>
                        <pre>{output}</pre>
                      </div>
                    )}
                  </div>
                )}
              </Row>
            </li>
          )
        })}
      </ol>
      {hasMore && (
        <div className="pod-chat-inspector-more">
          <Button variant="outline" size="xs" disabled={fetchingMore} aria-busy={fetchingMore} onClick={onFetchMore}>
            {t(fetchingMore ? 'pod.chat_timeline.loading_execution' : 'pod.chat_timeline.load_more_execution')}
          </Button>
        </div>
      )}
    </div>
  )
}
