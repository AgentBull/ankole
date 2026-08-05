import { z } from 'zod'

/** Job lifecycle status that the control plane's Job RPC responses report. */
export const BackgroundAgentJobStatusSchema = z.enum([
  'queued',
  'running',
  'waiting_on_user',
  'succeeded',
  'failed',
  'stopped'
])

export type BackgroundAgentJobStatus = z.output<typeof BackgroundAgentJobStatusSchema>
