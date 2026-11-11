import { Button } from '@ankole/uikit'
import { ChevronRightRegular, RecordStopRegular } from '@ankole/uikit/icons'
import { useMutation, useQueryClient } from '@tanstack/react-query'
import type { TFunction } from 'i18next'
import { useRef } from 'react'
import { useTranslation } from 'react-i18next'
import { stopConversationExecution } from '../api/generated/sdk.gen'
import type { PanelInputEvent } from '../panel-motion'
import { refreshConversationQueries } from '../query-cache'
import { ExecutionStatusMark, RunningElapsed, executionStatusLabelKey, executionStatusTone } from './execution-status'
import type { InspectorTarget, LinkedExecution } from './types'

export function cleanExecutionPreview(raw?: string | null): string | undefined {
  if (!raw) return undefined
  const trimmed = raw.trim()
  if (!trimmed || trimmed === '{}' || trimmed === '[]' || trimmed === 'null' || trimmed === '""') return undefined
  const plain = trimmed
    .replace(/```[\s\S]*?```/g, ' ')
    .replace(/^#{1,6}\s+/gm, '')
    .replace(/[*_`~>]/g, '')
    .replace(/\s+/g, ' ')
    .trim()
  return plain || undefined
}

type RunProgress = Pick<LinkedExecution, 'kind' | 'taskCounts' | 'planCompleted' | 'planTotal' | 'stepCount'>

/** How far a run has come: a Workflow's finished tasks, a Job's plan, or else the steps it has taken. */
export function executionProgressLabel(run: RunProgress, t: TFunction): string | undefined {
  if (run.kind === 'workflow' && run.taskCounts && run.taskCounts.total > 0) {
    return t('pod.chat_timeline.execution_workflow_counts', {
      completed: run.taskCounts.completed,
      total: run.taskCounts.total
    })
  }
  if (run.planTotal && run.planTotal > 0) {
    return t('pod.chat_timeline.execution_plan_progress', { completed: run.planCompleted ?? 0, total: run.planTotal })
  }
  if (run.stepCount && run.stepCount > 0) {
    return t('pod.chat_timeline.execution_steps_count', { count: run.stepCount })
  }
  return undefined
}

export function LinkedExecutionCard({
  run,
  conversationID,
  showAgentName = false,
  isActive = false,
  compact = false,
  onOpenInspector
}: {
  run: LinkedExecution
  conversationID: string
  showAgentName?: boolean
  isActive?: boolean
  compact?: boolean
  onOpenInspector?: (target: InspectorTarget, trigger?: HTMLElement | null, event?: PanelInputEvent) => void
}) {
  const { t } = useTranslation()
  const client = useQueryClient()
  const trigger = useRef<HTMLButtonElement>(null)

  const stopMutation = useMutation({
    mutationFn: () =>
      stopConversationExecution({
        path: { id: conversationID, kind: run.kind, run_id: Number(run.id) }
      }),
    onSuccess: () => {
      refreshConversationQueries(client, conversationID)
    }
  })

  const tone = executionStatusTone(run.status)
  const statusKey = executionStatusLabelKey(run.status)
  const statusLabel = statusKey ? t(statusKey) : undefined

  const metaParts: string[] = []
  if (showAgentName && run.agentName) {
    metaParts.push(run.agentName)
  } else if (run.kind === 'workflow') {
    metaParts.push(t('pod.chat_timeline.workflow'))
  }
  if (statusLabel) metaParts.push(statusLabel)

  const progress = executionProgressLabel(run, t)
  if (progress) metaParts.push(progress)

  const preview = !compact ? cleanExecutionPreview(run.summary) : undefined
  const workflowPct =
    run.kind === 'workflow' && run.taskCounts && run.taskCounts.total > 0
      ? Math.round((run.taskCounts.completed / run.taskCounts.total) * 100)
      : undefined

  const target: InspectorTarget = {
    type: 'execution',
    kind: run.kind,
    runID: run.id,
    title: run.title,
    agentName: run.agentName,
    initialRun: run
  }

  return (
    <div
      className="pod-chat-linked-run"
      data-status={tone}
      data-active={isActive || undefined}
      data-compact={compact || undefined}>
      <button
        ref={trigger}
        type="button"
        className="pod-chat-linked-run-main"
        aria-expanded={isActive}
        onClick={event => onOpenInspector?.(target, trigger.current, event.nativeEvent)}>
        <span className="pod-chat-linked-run-head">
          <ExecutionStatusMark status={run.status} />
          <strong className="pod-chat-linked-run-title" title={run.title}>
            {run.title}
          </strong>
          <RunningElapsed
            createdAt={run.createdAt}
            startedAt={run.startedAt}
            completedAt={run.completedAt}
            updatedAt={run.updatedAt}
            status={run.status}
          />
          <ChevronRightRegular className="pod-chat-linked-run-chevron" aria-hidden />
        </span>
        {metaParts.length > 0 && <small className="pod-chat-linked-run-meta">{metaParts.join(' · ')}</small>}
        {preview && <span className="pod-chat-linked-run-preview">{preview}</span>}
        {workflowPct !== undefined && (
          <span className="pod-chat-workflow-bar" aria-hidden>
            <span style={{ width: `${workflowPct}%` }} data-failed={(run.taskCounts?.failed ?? 0) > 0 || undefined} />
          </span>
        )}
      </button>
      {Boolean(run.stoppable) && !compact && (
        <Button
          size="xs"
          variant="ghost"
          className="pod-chat-linked-run-stop"
          disabled={stopMutation.isPending}
          aria-label={`${t('pod.chat_timeline.execution_stop_action')} ${run.title}`}
          onClick={() => stopMutation.mutate()}>
          <RecordStopRegular aria-hidden />
          <span>
            {t(
              stopMutation.isPending
                ? 'pod.chat_timeline.execution_stopping'
                : 'pod.chat_timeline.execution_stop_action'
            )}
          </span>
        </Button>
      )}
    </div>
  )
}
