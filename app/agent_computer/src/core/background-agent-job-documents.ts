/**
 * Hand-written shapes of the deliberately free-form `*_json` documents the
 * worker produces or consumes inside the generated Background Agent Job
 * messages. They are documentation-grade contracts: the control plane
 * persists them as JSON and the model reads their rendered form.
 *
 * The zod schemas are the consumer-side envelope checks and stay tolerant on
 * purpose — a stored document from an older worker must still parse, so they
 * pin the envelope (`format`/`version`, status vocabulary) and leave message
 * bodies loose, while the TS types state the precise shape the current
 * producer writes.
 */

import { z } from 'zod'
import type { JsonObject as JSONObject } from '@agentbull/active-support'

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

const terminalStatuses: ReadonlySet<string> = new Set([
  'succeeded',
  'failed',
  'stopped'
] satisfies BackgroundAgentJobStatus[])

/** A terminal job accepts no further turns or messages. */
export function isTerminalBackgroundAgentJobStatus(status: string): boolean {
  return terminalStatuses.has(status)
}

export type BackgroundAgentJobTurnStatus = 'in_progress' | 'completed' | 'failed' | 'interrupted'
export type BackgroundAgentJobTurnKind = 'agent' | 'compaction'

export type BackgroundAgentJobTurnTrajectoryMetadata = JSONObject & {
  redacted?: boolean
  content_truncated?: boolean
}

export type BackgroundAgentJobTurnTrajectoryHeader = JSONObject & {
  format: 'ankole_chatml'
  version: 1
  metadata?: BackgroundAgentJobTurnTrajectoryMetadata
}

/**
 * One sanitized semantic thread item pending checkpoint. The control plane
 * stores the item stream verbatim and derives the trajectory-group
 * projection from it.
 */
export type BackgroundAgentJobTurnItemEntry = JSONObject & {
  position: number
  item_key: string
  item: JSONObject
}

export type BackgroundAgentJobTurnUsageBreakdown = JSONObject & {
  total_tokens: number
  input_tokens: number
  cached_input_tokens: number
  output_tokens: number
  reasoning_output_tokens: number
}

export type BackgroundAgentJobTurnUsage = JSONObject & {
  thread_total: BackgroundAgentJobTurnUsageBreakdown
  last_model_call: BackgroundAgentJobTurnUsageBreakdown
  model_context_window?: number
}

export type BackgroundAgentJobTurnPlan = JSONObject & {
  explanation?: string
  steps: Array<
    JSONObject & {
      step: string
      status: 'pending' | 'in_progress' | 'completed'
    }
  >
}

export type BackgroundAgentJobTurnToolUsage = JSONObject & {
  namespace?: string
  name: string
  calls: number
}

export type BackgroundAgentJobTurnToolExecutionMechanism = JSONObject & {
  namespace?: string
  name: string
  execution_mechanism: 'provider_hosted' | 'local_dynamic'
  calls: number
}

export type BackgroundAgentJobTurnActiveItem = JSONObject & {
  id: string
  namespace?: string
  name: string
}

export type BackgroundAgentJobTurnProgress = JSONObject & {
  completed_items: number
  tool_calls: number
  tools_used: BackgroundAgentJobTurnToolUsage[]
  tool_execution_mechanisms?: BackgroundAgentJobTurnToolExecutionMechanism[]
  files_changed: string[]
  skills_used?: string[]
  plan?: BackgroundAgentJobTurnPlan
  active_item?: BackgroundAgentJobTurnActiveItem
}
