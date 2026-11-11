import { useEffect, useRef, useState } from 'react'
import { Spinner } from '@ankole/uikit'
import { useTranslation } from 'react-i18next'
import type { PodActivity, PodActivityItem } from '../api'
import type { ExecutionStep, ExecutionSummary } from './types'
import { RunningElapsed } from './execution-status'
import { ToolRunView, localizedStepTitle, humanizeToolName } from './tool-run-view'
import { UsageDetails, UsageSummary } from './execution-usage'

export function WorkingLabel({ text }: { text: string }) {
  const [phase, setPhase] = useState({ text, leaving: '', sequence: 0 })
  if (phase.text !== text) {
    setPhase({ text, leaving: phase.text, sequence: phase.sequence + 1 })
  }
  return (
    <span className="relative inline-grid min-w-0 max-w-full overflow-hidden align-bottom text-fg-secondary">
      {phase.leaving && (
        <span
          key={phase.sequence - 1}
          aria-hidden
          className="pointer-events-none absolute inset-0 motion-safe:animate-[pod-chat-phase-out_320ms_cubic-bezier(.22,1,.36,1)_both] motion-reduce:hidden"
          onAnimationEnd={() =>
            setPhase(current => (current.sequence === phase.sequence ? { ...current, leaving: '' } : current))
          }>
          {phase.leaving}
        </span>
      )}
      <span
        key={phase.sequence}
        data-working-phase={text}
        className={`relative ${
          phase.sequence > 0 ? 'motion-safe:animate-[pod-chat-phase-in_460ms_cubic-bezier(.22,1,.36,1)_both]' : ''
        }`}>
        {text}
      </span>
    </span>
  )
}

export function CollapsedWorkView({
  execution,
  active = false,
  phaseLabel,
  startedAt,
  attention = false
}: {
  execution: ExecutionSummary
  active?: boolean
  phaseLabel?: string
  startedAt?: string
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
  const stopped = ['stopped', 'cancelled'].includes(execution.status ?? '')
  // A step can fail while its turn recovers and finishes, so only the turn's own status fails it.
  const failed = stopped || ['error', 'failed'].includes(execution.status ?? '')
  const outcome = active ? undefined : stopped ? 'stopped' : failed ? 'failed' : undefined
  const errors = steps.filter(step => ['error', 'failed'].includes(step.status)).length
  // Only thinking before the first step folds away; once steps exist the list stays open while the model pauses
  // between them, so whatever the reader opened inside it survives.
  const thinkingDisclosure = active && !steps.length
  const urgent = attention || failed
  const [expanded, setExpanded] = useState((active && !thinkingDisclosure) || urgent)
  const userToggled = useRef(false)
  const prevUrgent = useRef(urgent)
  useEffect(() => {
    if (urgent && !prevUrgent.current) userToggled.current = false
    prevUrgent.current = urgent
    if (userToggled.current) return
    if ((active && !thinkingDisclosure) || urgent) setExpanded(true)
    // A finished turn folds its steps away, as it does when its message first loads, unless the reader chose.
    else setExpanded(false)
  }, [active, thinkingDisclosure, urgent])
  const elapsed = active && startedAt && (
    <span aria-live="off" className="ms-1 shrink-0 empty:hidden">
      <RunningElapsed createdAt={startedAt} status="running" />
    </span>
  )
  if (!steps.length && !thinking && !usage) {
    if (!active) return null
    return (
      <div className="pod-chat-work pod-chat-work-status" role="status">
        <Spinner aria-hidden className="pod-chat-working-spinner" />
        <WorkingLabel text={phaseLabel || t('pod.chat_timeline.thinking')} />
        {elapsed}
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
        {active ? (
          <WorkingLabel
            text={
              runningSteps.map(step => localizedStepTitle(step, t)).join(' · ') ||
              phaseLabel ||
              t('pod.chat_timeline.thinking')
            }
          />
        ) : (
          <span>{settledSummary}</span>
        )}
        {elapsed}
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
