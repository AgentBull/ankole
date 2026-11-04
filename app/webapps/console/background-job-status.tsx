import { useTranslation } from 'react-i18next'
import { StatusIndicator } from './console-form'
import type { BackgroundAgentJobItem } from './api/background-agent-jobs'
type JobStatus = BackgroundAgentJobItem['status']

export function BackgroundJobStatus({ status }: { status: JobStatus }) {
  const { t } = useTranslation()
  const tone =
    status === 'failed' || status === 'stopped'
      ? 'danger'
      : status === 'succeeded'
        ? 'positive'
        : status === 'running'
          ? 'info'
          : status === 'waiting_on_user'
            ? 'waiting'
            : 'neutral'

  return <StatusIndicator tone={tone}>{t(`console.background_agent_jobs.status_${status}`)}</StatusIndicator>
}
