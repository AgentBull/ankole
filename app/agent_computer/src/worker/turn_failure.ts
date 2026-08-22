import type { JsonObject as JSONObject } from '@agentbull/active-support'
import { classifyLLMError } from '../core/llm-error-classifier'

/**
 * Converts an arbitrary Turn failure into durable details for the control plane.
 *
 * The Worker does not decide the final retry policy. It preserves LLM and
 * AIGateway classification so the Turn owner can make that decision.
 */
export function turnFailureDetails(error: unknown): JSONObject {
  const classification = classifyLLMError(error)
  const workerError = workerErrorDetails(error)
  const details: JSONObject = {
    runtime: 'bun',
    llm_error_kind: classification.kind,
    retryable: workerError.retryable ?? classification.retryable,
    should_compress: classification.shouldCompress,
    should_fallback_provider: classification.shouldFallbackProvider
  }

  if (workerError.code) details.error_code = workerError.code
  if (workerError.retryAt) details.retry_at = workerError.retryAt

  const gateway = aigatewayErrorDetails(error)
  if (gateway) details.aigateway = gateway

  return details
}

/** Projects durable failure classification into flat indexed log fields. */
export function turnFailureLogFields(error: unknown): JSONObject {
  const classification = classifyLLMError(error)
  const workerError = workerErrorDetails(error)
  const gateway = aigatewayErrorDetails(error)

  return {
    llm_error_kind: classification.kind,
    retryable: workerError.retryable ?? classification.retryable,
    should_compress: classification.shouldCompress,
    should_fallback_provider: classification.shouldFallbackProvider,
    ...(workerError.code ? { error_code: workerError.code } : {}),
    ...(typeof gateway?.status === 'number' ? { aigateway_status: gateway.status } : {})
  }
}

/**
 * Extracts structured AIGateway error fields without depending on one concrete
 * error class. HTTP and WebSocket paths can surface different error shapes.
 */
export function aigatewayErrorDetails(error: unknown): JSONObject | undefined {
  if (!error || typeof error !== 'object') return undefined

  const record = error as JSONObject
  const details: JSONObject = {}

  if (typeof record.code === 'string') details.code = record.code
  if (typeof record.status === 'number') details.status = record.status
  if (record.details && typeof record.details === 'object' && !Array.isArray(record.details)) {
    details.details_json = record.details as JSONObject
  }

  return Object.keys(details).length > 0 ? details : undefined
}

function workerErrorDetails(error: unknown): { code?: string; retryable?: boolean; retryAt?: string } {
  if (!error || typeof error !== 'object') return {}
  const record = error as { code?: unknown; retryable?: unknown; retryAt?: unknown }
  return {
    ...(typeof record.code === 'string' ? { code: record.code } : {}),
    ...(typeof record.retryable === 'boolean' ? { retryable: record.retryable } : {}),
    ...(typeof record.retryAt === 'string' ? { retryAt: record.retryAt } : {})
  }
}
