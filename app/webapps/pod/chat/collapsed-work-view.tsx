import { useEffect, useRef, useState } from 'react'
import { Spinner } from '@ankole/uikit'
import { useTranslation } from 'react-i18next'
import type { PodActivity, PodActivityItem } from '../api'
import type { ExecutionStep, ExecutionSummary } from './types'
import { ToolRunView, localizedStepTitle, humanizeToolName } from './tool-run-view'
import { UsageDetails, UsageSummary } from './execution-usage'

export function CollapsedWorkView({
  execution,
  active = false,
  phaseLabel,
  attention = false
}: {
  execution: ExecutionSummary
  active?: boolean
  phaseLabel?: string
  attention?: boolean
}) {
  const { t } = useTranslation()
  const steps = execution.steps ?? []
  const thinking = execution.thinking_summary
  const usage = active ? undefined : execution.usage
  const runningSteps = steps.filter(
    step =>
      !['completed', 'complete', 'success', 'succeeded', 'settled', 'stopped', 'cancelled', 'failed', 'error'].includes(
        step.status
      )
  )
  const current = runningSteps.at(-1)
  const stopped = ['stopped', 'cancelled'].includes(execution.status ?? '')
  // A step can fail while its turn recovers and finishes, so only the turn's own status fails it.
  const failed = stopped || ['error', 'failed'].includes(execution.status ?? '')
  const outcome = active ? undefined : stopped ? 'stopped' : failed ? 'failed' : undefined
  const errors = steps.filter(step => ['error', 'failed'].includes(step.status)).length
  const thinkingDisclosure = active && !current
  const urgent = attention || failed
  const [expanded, setExpanded] = useState((active && !thinkingDisclosure) || urgent)
  const userToggled = useRef(false)
  const prevUrgent = useRef(urgent)
  useEffect(() => {
    if (urgent && !prevUrgent.current) userToggled.current = false
    prevUrgent.current = urgent
    if (userToggled.current) return
    if ((active && !thinkingDisclosure) || urgent) setExpanded(true)
    else if (thinkingDisclosure) setExpanded(false)
  }, [active, thinkingDisclosure, urgent])
  if (!steps.length && !thinking && !usage) {
    if (!active) return null
    return (
      <div className="pod-chat-work pod-chat-work-status" role="status">
        <Spinner aria-hidden className="pod-chat-working-spinner" />
        <span className="pod-chat-working-label">{phaseLabel || t('pod.chat_timeline.thinking')}</span>
      </div>
    )
  }
  const settledSummary = outcome
    ? t(`pod.chat_timeline.${outcome}`)
    : steps.length > 0
      ? t('pod.chat_timeline.steps')
      : thinking
        ? t('pod.chat_timeline.thinking')
        : t('pod.chat_timeline.usage_title')
  return (
    <details
      className={`pod-chat-work${thinkingDisclosure ? ' pod-chat-thinking' : ''}`}
      data-outcome={outcome}
      open={expanded}
      onToggle={event => {
        if (event.currentTarget.open !== expanded) {
          userToggled.current = true
          setExpanded(event.currentTarget.open)
        }
      }}>
      <summary title={execution.model ?? undefined}>
        {active && <Spinner aria-hidden className="pod-chat-working-spinner" />}
        <span className={active ? 'pod-chat-working-label' : undefined}>
          {active
            ? runningSteps.map(step => localizedStepTitle(step, t)).join(' · ') ||
              phaseLabel ||
              t('pod.chat_timeline.thinking')
            : settledSummary}
        </span>
        {!active && !outcome && errors > 0 && (
          <span className="pod-chat-work-errors">· {t('pod.chat_timeline.error_count', { count: errors })}</span>
        )}
        {usage && <UsageSummary usage={usage} />}
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
          {usage && <UsageDetails usage={usage} />}
        </div>
      )}
    </details>
  )
}

export function activitySteps(activity: PodActivity, label: (item: PodActivityItem) => string): ExecutionStep[] {
  return activity.tools.map(item => ({
    id: item.operation_id,
    tool: item.tool || item.operation_id,
    title: label(item),
    label_key: item.label_key,
    label_bindings: item.label_bindings,
    skill_name:
      item.tool === 'skill_view' && typeof item.label_bindings?.name === 'string'
        ? item.label_bindings.name
        : undefined,
    status: item.phase ?? 'running',
    duration_ms: item.duration_ms ?? undefined
  }))
}

export function useActivityLabel() {
  const { t } = useTranslation()
  return (item: PodActivityItem, isTool = false) => {
    const fallback =
      isTool && !/^(?:call_|toolu_|[0-9a-f]{8}-)/i.test(item.operation_id)
        ? humanizeToolName(item.operation_id)
        : t('pod.chat.replying')
    return item.label_key?.startsWith('conversations.delivery.reply.activity.')
      ? t(item.label_key, { ...item.label_bindings, defaultValue: item.label || fallback })
      : item.label || fallback
  }
}

export function ActivityView({ activity }: { activity: PodActivity }) {
  const label = useActivityLabel()
  return (
    <CollapsedWorkView
      active
      phaseLabel={activity.phase ? label(activity.phase) : undefined}
      execution={{
        steps: activitySteps(activity, item => label(item, true))
      }}
    />
  )
}
