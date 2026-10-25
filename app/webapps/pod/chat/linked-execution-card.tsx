import { Button, Sheet, SheetContent, SheetTitle } from '@ankole/uikit'
import {
  RiArrowRightSLine,
  RiCheckLine,
  RiCloseLine,
  RiLoader4Line,
  RiNodeTree,
  RiQuestionLine
} from '@remixicon/react'
import { useEffect, useRef, useState } from 'react'
import { useTranslation } from 'react-i18next'
import { useInfiniteQuery } from '@tanstack/react-query'
import { ChatMarkdown } from './chat-markdown'
import { ContentError } from '../content-primitives'
import { podKeys } from '../api'
import { conversationExecution } from '../api/generated/sdk.gen'
import type { LinkedExecution } from './types'

const statusLabels: Record<string, string> = {
  queued: 'queued',
  running: 'running',
  waiting_on_user: 'decision_needed',
  awaiting_input: 'decision_needed',
  succeeded: 'completed',
  completed: 'completed',
  failed: 'failed',
  stopped: 'stopped',
  cancelled: 'stopped'
}

export function LinkedExecutionCard({ run, conversationID }: { run: LinkedExecution; conversationID: string }) {
  const { t } = useTranslation()
  const [open, setOpen] = useState(false)
  const trigger = useRef<HTMLButtonElement>(null)
  const running = run.status === 'running' || run.status === 'queued'
  const failed = run.status === 'failed'
  const waiting = run.status === 'waiting_on_user' || run.status === 'awaiting_input'
  const stopped = ['stopped', 'cancelled'].includes(run.status)
  const complete = run.status === 'succeeded' || run.status === 'completed'
  const [now, setNow] = useState(Date.now)
  useEffect(() => {
    if (!running) return
    const timer = setInterval(() => setNow(Date.now()), 1000)
    return () => clearInterval(timer)
  }, [running, run.createdAt])
  const duration = Math.max(0, (running ? now : Date.parse(run.updatedAt)) - Date.parse(run.createdAt))
  const status = statusLabels[run.status] ? t(`pod.chat_timeline.${statusLabels[run.status]}`) : undefined
  return (
    <>
      <button
        ref={trigger}
        type="button"
        className="pod-chat-linked-run"
        data-status={waiting ? 'waiting' : failed ? 'failed' : run.status}
        onClick={() => setOpen(true)}>
        <RiNodeTree aria-hidden />
        <span>
          <strong>{run.title}</strong>
          <small>
            {run.agentName ||
              t(run.kind === 'workflow' ? 'pod.chat_timeline.workflow' : 'pod.chat_timeline.background_work')}
            {status ? ` · ${status}` : ''}
          </small>
        </span>
        <time>{(duration / 1000).toFixed(1)}s</time>
        {running ? (
          <RiLoader4Line className="animate-spin" aria-hidden />
        ) : waiting ? (
          <RiQuestionLine aria-hidden />
        ) : failed || stopped ? (
          <RiCloseLine aria-hidden />
        ) : complete ? (
          <RiCheckLine aria-hidden />
        ) : null}
        <RiArrowRightSLine aria-hidden />
      </button>
      <Sheet open={open} onOpenChange={setOpen}>
        <SheetContent className="pod-chat-execution-drawer" closeLabel={t('common.close')} finalFocus={trigger}>
          <SheetTitle>{run.title}</SheetTitle>
          <div className="pod-chat-execution-detail">
            <dl>
              <dt>{t('pod.chat_timeline.status')}</dt>
              <dd>{status || t('pod.chat_timeline.background_work')}</dd>
              {run.agentName && (
                <>
                  <dt>{t('pod.chat_timeline.agent')}</dt>
                  <dd>{run.agentName}</dd>
                </>
              )}
            </dl>
            {open && <ExecutionLog conversationID={conversationID} run={run} />}
          </div>
          <Button variant="ghost" onClick={() => setOpen(false)}>
            {t('common.close')}
          </Button>
        </SheetContent>
      </Sheet>
    </>
  )
}

function ExecutionLog({ conversationID, run }: { conversationID: string; run: LinkedExecution }) {
  const { t } = useTranslation()
  const logs = useInfiniteQuery({
    queryKey: [...podKeys.detail(conversationID), 'execution', run.kind, run.id],
    initialPageParam: null,
    queryFn: ({ pageParam, signal }: { pageParam: string | null; signal: AbortSignal }) =>
      conversationExecution({
        path: { id: conversationID, kind: run.kind, run_id: Number(run.id) },
        query: { cursor: pageParam ?? undefined },
        signal
      }),
    getNextPageParam: page => page.nextCursor ?? undefined,
    retry: false,
    refetchInterval: query =>
      !query.state.error && ['queued', 'running', 'waiting_on_user', 'awaiting_input'].includes(run.status)
        ? 2000
        : false
  })
  const pages = run.kind === 'background_agent_job' ? logs.data?.pages.toReversed() : logs.data?.pages
  const text = pages
    ?.map(page => page.text)
    .filter(Boolean)
    .join('\n\n')
  const earlier = run.kind === 'background_agent_job'
  const more = logs.hasNextPage && (
    <Button
      variant="outline"
      size="sm"
      disabled={logs.isFetchingNextPage}
      focusableWhenDisabled
      aria-busy={logs.isFetchingNextPage}
      onClick={() => void logs.fetchNextPage()}>
      {t(
        logs.isFetchingNextPage
          ? 'pod.chat_timeline.loading_execution'
          : earlier
            ? 'pod.chat_timeline.load_earlier_execution'
            : 'pod.chat_timeline.load_more_execution'
      )}
    </Button>
  )
  return (
    <>
      {logs.isPending && <p role="status">{t('pod.chat_timeline.loading_execution')}</p>}
      {earlier && more}
      {text && <ChatMarkdown text={text} />}
      {!logs.isPending && !logs.error && !text && (
        <p className="text-fg-tertiary">{t('pod.chat_timeline.no_execution_steps')}</p>
      )}
      <ContentError error={logs.error} retry={() => void logs.refetch()} />
      {!earlier && more}
    </>
  )
}
