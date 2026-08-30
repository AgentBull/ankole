import { positiveInteger } from '../../common/numbers'
import type { TurnStart } from '../../lanes/actor_lane'
import { deepString, isRecord, ms, type JsonObject as JSONObject } from '@agentbull/active-support'

export type AgentRuntimePolicy = {
  maxOutputTokens?: number
  maxIterations: number
  inactivityTimeoutMs: number
}

// Stop an inactive provider call when the control plane sets no Turn-specific
// limit. Active tool work refreshes this deadline.
const textTurnDefaultInactivityTimeoutMs = ms('35m')

/**
 * Applies control-plane loop limits to the Worker.
 *
 * The model limit caps output tokens. max_iterations stays required because
 * the Worker must not invent a loop budget.
 */
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

/**
 * True when the Agent leaves web search to its language-model Provider.
 *
 * The Worker then declares no `web_search` tool at all. That holds even when the
 * Provider turns out not to run search: the Agent said search belongs to its
 * model, so quietly substituting an Ankole search Provider would change who
 * executes the work and what the result looks like.
 *
 * Whether the Provider actually performs a search this turn is a separate fact,
 * carried by the hosted tool declaration.
 */
export function webSearchIsProviderHosted(turnStart: TurnStart): boolean {
  const rawPolicy = turnStart.request_context?.ai_agent
  const policy = isRecord(rawPolicy) ? rawPolicy : {}
  const hosted = isRecord(policy.provider_hosted) ? policy.provider_hosted : {}
  return hosted.web_search === true
}

/**
 * Requests AIGateway truncation only after the control plane journals an
 * overflow retry. Ordinary Turns preserve the adopted Response chain.
 */
export function statefulTruncationFromActorEventPayload(payload: JSONObject | undefined): 'auto' | undefined {
  const retryReason =
    deepString(payload, ['data', 'entry', 'retry_reason']) || deepString(payload, ['data', 'internal', 'retry_reason'])

  return retryReason === 'overflow_retry' ? 'auto' : undefined
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
