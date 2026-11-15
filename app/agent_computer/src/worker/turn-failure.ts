import type { JsonObject as JSONObject } from '@agentbull/active-support'
import { RuntimeFabricTransportError } from '../fabric/fabric'

/**
 * Converts a Turn failure into durable details for the control plane.
 *
 * The control plane decides the retry policy from these fields. An error is
 * retryable only when its class says so; an unexpected error fails loudly.
 */
export function turnFailureDetails(error: unknown): JSONObject {
  const { code, retryable, retryAt } = failureFields(error)
  return {
    runtime: 'bun',
    retryable,
    ...(code ? { error_code: code } : {}),
    ...(retryAt ? { retry_at: retryAt } : {})
  }
}

/** Projects the failure fields into flat indexed log fields. */
export function turnFailureLogFields(error: unknown): JSONObject {
  const { code, retryable } = failureFields(error)
  return { retryable, ...(code ? { error_code: code } : {}) }
}

function failureFields(error: unknown): { code?: string; retryable: boolean; retryAt?: string } {
  if (error instanceof RuntimeFabricTransportError) {
    return { code: error.code === 'timeout' ? 'runtime_fabric_timeout' : error.code, retryable: error.retryable }
  }
  if (!error || typeof error !== 'object') return { retryable: false }
  const record = error as { code?: unknown; retryable?: unknown; retryAt?: unknown }
  return {
    ...(typeof record.code === 'string' && record.code ? { code: record.code } : {}),
    retryable: record.retryable === true,
    ...(typeof record.retryAt === 'string' ? { retryAt: record.retryAt } : {})
  }
}
