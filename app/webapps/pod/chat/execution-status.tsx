import { RiCheckLine, RiCloseCircleLine, RiQuestionLine, RiStopCircleLine, RiTimeLine } from '@remixicon/react'
import { Spinner } from '@ankole/uikit'
import { useEffect, useState } from 'react'
import { useTranslation } from 'react-i18next'
import { formatElapsed } from './elapsed'

export function isLiveExecutionStatus(status?: string | null): boolean {
  return ['queued', 'running', 'waiting_on_user', 'awaiting_input', 'sleeping'].includes(status ?? '')
}

export function isTickingExecutionStatus(status?: string | null): boolean {
  return status === 'running' || status === 'queued'
}

export function executionStatusLabelKey(status?: string | null): string | undefined {
  switch (status) {
    case 'queued':
      return 'pod.chat_timeline.execution_queued'
    case 'running':
      return 'pod.chat_timeline.running'
    case 'waiting_on_user':
    case 'awaiting_input':
      return 'pod.chat_timeline.execution_waiting_user'
    case 'sleeping':
      return 'pod.chat_timeline.execution_sleeping'
    case 'succeeded':
    case 'completed':
      return 'pod.chat_timeline.completed'
    case 'failed':
      return 'pod.chat_timeline.failed'
    case 'stopped':
    case 'cancelled':
      return 'pod.chat_timeline.execution_stopped'
    default:
      return undefined
  }
}

export type ExecutionStatusTone = 'running' | 'waiting' | 'sleeping' | 'failed' | 'stopped' | 'completed'

export function executionStatusTone(status?: string | null): ExecutionStatusTone {
  switch (status) {
    case 'waiting_on_user':
    case 'awaiting_input':
      return 'waiting'
    case 'sleeping':
      return 'sleeping'
    case 'failed':
      return 'failed'
    case 'stopped':
    case 'cancelled':
      return 'stopped'
    case 'succeeded':
    case 'completed':
      return 'completed'
    default:
      return 'running'
  }
}

export function ExecutionStatusMark({ status }: { status?: string | null }) {
  const tone = executionStatusTone(status)
  if (tone === 'running') {
    return <Spinner aria-hidden className="pod-chat-working-spinner" />
  }
  const Icon =
    tone === 'waiting'
      ? RiQuestionLine
      : tone === 'sleeping'
        ? RiTimeLine
        : tone === 'failed'
          ? RiCloseCircleLine
          : tone === 'stopped'
            ? RiStopCircleLine
            : RiCheckLine
  return <Icon className="pod-chat-exec-status-icon" data-tone={tone} aria-hidden />
}

function formatLiveSeconds(ms: number, locale: string): string {
  const seconds = Math.floor(Math.max(0, ms) / 1000)
  return new Intl.NumberFormat(locale, {
    style: 'unit',
    unit: 'second',
    unitDisplay: 'narrow',
    maximumFractionDigits: 0
  }).format(seconds)
}

export function RunningElapsed({
  createdAt,
  startedAt,
  completedAt,
  updatedAt,
  status
}: {
  createdAt: string
  startedAt?: string | null
  completedAt?: string | null
  updatedAt?: string | null
  status?: string | null
}) {
  const { i18n } = useTranslation()
  const ticking = isTickingExecutionStatus(status)
  const [now, setNow] = useState(Date.now)
  useEffect(() => {
    if (!ticking) return
    setNow(Date.now())
    const timer = setInterval(() => setNow(Date.now()), 1000)
    return () => clearInterval(timer)
  }, [ticking, startedAt, createdAt])

  const startMs = Date.parse(startedAt || createdAt)
  const endMs = ticking ? now : Date.parse(completedAt || updatedAt || createdAt)
  const duration = Math.max(0, endMs - startMs)
  if (!Number.isFinite(duration) || duration < 1000) return null
  const label =
    ticking && duration < 60_000 ? formatLiveSeconds(duration, i18n.language) : formatElapsed(duration, i18n.language)
  return <time className="pod-chat-exec-elapsed">{label}</time>
}
