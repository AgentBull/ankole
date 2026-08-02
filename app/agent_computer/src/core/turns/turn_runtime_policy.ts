import type { TurnStart } from '../../lanes/actor_lane'
import { isRecord, ms } from '@agentbull/active-support'

export type AgentRuntimePolicy = {
  maxOutputTokens?: number
  maxIterations: number
  inactivityTimeoutMs: number
}

const textTurnDefaultInactivityTimeoutMs = ms('35m')

export function agentRuntimePolicyFromTurnStart(turnStart: TurnStart): AgentRuntimePolicy {
  const rawPolicy = turnStart.request_context?.ai_agent
  const policy = isRecord(rawPolicy) ? rawPolicy : {}
  const maxOutputTokens = positiveInteger(policy.max_output_tokens)
  const maxIterations = requiredPositiveInteger(policy.max_iterations, 'request_context.ai_agent.max_iterations')
  const modelMaxCompletionTokens = positiveInteger(turnStart.model_ref?.max_completion_tokens)
  const inactivityTimeoutMs = nonNegativeInteger(policy.inactivity_timeout_ms) ?? textTurnDefaultInactivityTimeoutMs

  return {
    ...(maxOutputTokens ? { maxOutputTokens: clampPositiveInteger(maxOutputTokens, modelMaxCompletionTokens) } : {}),
    maxIterations,
    inactivityTimeoutMs
  }
}

function positiveInteger(value: unknown): number | undefined {
  return typeof value === 'number' && Number.isInteger(value) && value > 0 ? value : undefined
}

function requiredPositiveInteger(value: unknown, field: string): number {
  const parsed = positiveInteger(value)
  if (parsed === undefined) throw new Error(`${field} must be a positive integer`)
  return parsed
}

function nonNegativeInteger(value: unknown): number | undefined {
  return typeof value === 'number' && Number.isInteger(value) && value >= 0 ? value : undefined
}

function clampPositiveInteger(value: number, ceiling: number | undefined): number {
  return ceiling ? Math.min(value, ceiling) : value
}
