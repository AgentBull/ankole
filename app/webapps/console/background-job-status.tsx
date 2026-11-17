import { useTranslation } from 'react-i18next'
import { StatusIndicator } from './console-form'
import type { BackgroundAgentJobItem } from './api/background-agent-jobs'

type JobStatus = BackgroundAgentJobItem['status']
type StatusTone = 'danger' | 'positive' | 'info' | 'waiting' | 'neutral'

const STATUS_TONES: Record<string, StatusTone> = {
  failed: 'danger',
  stopped: 'danger',
  succeeded: 'positive',
  running: 'info',
  waiting_on_user: 'waiting'
}

export function BackgroundJobStatus({ status }: { status: JobStatus | (string & {}) }) {
  const { t } = useTranslation()
  const tone = STATUS_TONES[status] ?? 'neutral'

  return (
    <StatusIndicator tone={tone}>
      {t(`console.background_agent_jobs.status_${status}`, { defaultValue: status })}
    </StatusIndicator>
  )
}
