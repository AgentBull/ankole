import { useEffect, useState } from 'react'
import { useTranslation } from 'react-i18next'
import type { ExecutionSummary } from './types'
import { ToolRunView } from './tool-run-view'

export function CollapsedWorkView({
  execution,
  active = false,
  startedAt,
  attention = false
}: {
  execution: ExecutionSummary
  active?: boolean
  startedAt?: string
  attention?: boolean
}) {
  const { t } = useTranslation()
  const [now, setNow] = useState(Date.now)
  useEffect(() => {
    if (!active || !startedAt) return
    const timer = setInterval(() => setNow(Date.now()), 1000)
    return () => clearInterval(timer)
  }, [active, startedAt])
  const steps = execution.steps ?? []
  const thinking = execution.thinking_summary
  const duration = active && startedAt ? Math.max(0, now - Date.parse(startedAt)) : execution.duration_ms
  const current = steps.findLast(
    step =>
      !['completed', 'complete', 'success', 'succeeded', 'settled', 'stopped', 'cancelled', 'failed', 'error'].includes(
        step.status
      )
  )
  const failed =
    steps.some(step => ['error', 'failed'].includes(step.status)) ||
    ['error', 'failed', 'stopped', 'cancelled'].includes(execution.status ?? '')
  const thinkingDisclosure = active && !current
  const [expanded, setExpanded] = useState((active && !thinkingDisclosure) || attention || failed)
  useEffect(() => {
    if ((active && !thinkingDisclosure) || attention || failed) setExpanded(true)
    else if (thinkingDisclosure) setExpanded(false)
  }, [active, thinkingDisclosure, attention, failed])
  if (!steps.length && !thinking && !active) return null
  const pagesRead = steps.filter(step => /page.*read|read.*page/.test(step.tool)).length
  return (
    <details
      className={`pod-chat-work${thinkingDisclosure ? ' pod-chat-thinking' : ''}`}
      open={expanded}
      onToggle={event => setExpanded(event.currentTarget.open)}>
      <summary>
        {active && <span className="pod-chat-working-dot" aria-hidden />}
        <span>
          {active
            ? current?.title || t('pod.chat_timeline.thinking')
            : t('pod.chat_timeline.worked_for', {
                seconds: ((duration ?? 0) / 1000).toFixed(1),
                count: steps.length
              })}
        </span>
        {active && duration != null && <time>{(duration / 1000).toFixed(1)}s</time>}
        {thinkingDisclosure && steps.length > 0 && (
          <span> · {t('pod.chat_timeline.tool_count', { count: steps.length })}</span>
        )}
        {!active && pagesRead > 0 && (
          <span className="pod-chat-work-pages">· {t('pod.chat_timeline.pages_read', { count: pagesRead })}</span>
        )}
      </summary>
      {expanded && (
        <div className="pod-chat-work-content">
          {thinking && thinkingDisclosure ? (
            <div className="pod-chat-thinking-text">{thinking}</div>
          ) : (
            thinking && (
              <details className="pod-chat-thinking">
                <summary>{t('pod.chat_timeline.thinking')}</summary>
                <div className="whitespace-pre-wrap">{thinking}</div>
              </details>
            )
          )}
          <ToolRunView steps={steps} compact={active} />
        </div>
      )}
    </details>
  )
}
