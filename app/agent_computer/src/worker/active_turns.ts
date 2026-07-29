import { classifyLLMError } from '../core/llm-error-classifier'
import { workerProgressEnvelope } from '../fabric/envelopes'
import type { JsonObject as JSONObject } from '@pleisto/active-support'
import { isRuntimeFabricTransportError, type EnvelopeSender } from '../fabric/fabric'
import type { ActorTurnRef, TurnStart, TurnSteerUpdate } from '../lanes/actor_lane'
import type { WorkerConfig } from './config'
import { workerLogger } from './logging'

const turnProgressIntervalMs = 60_000

export type ActiveTurn = {
  turnStart: TurnStart
  correlationID: string
  steeringUpdates: TurnSteerUpdate[]
  abortController: AbortController
  controlledStopRequested: boolean
  controlledStopCommand?: string
  controlledStopReason?: string
}

/**
 * Reports remaining turn capacity from in-memory worker state.
 *
 * The control plane owns scheduling, but the worker still publishes this small
 * hint so admission can avoid sending work to a full process.
 */
export function availableTurnSlots(config: WorkerConfig, activeTurns: Map<string, ActiveTurn>): number {
  return Math.max(config.maxConcurrentTurns - activeTurns.size, 0)
}

/**
 * Starts periodic progress checkpoints for a turn.
 *
 * Progress is intentionally best-effort and non-overlapping. A stuck progress
 * send should not pile up timers or block the model/tool loop it is describing.
 */
export type TurnProgressReporter = {
  touch: (summary?: string) => void
  stop: () => void
}

export function startTurnProgress(
  sendEnvelope: EnvelopeSender,
  active: ActiveTurn,
  opts: { intervalMs?: number } = {}
): TurnProgressReporter {
  let stopped = false
  let progressInFlight = false
  let activitySummary = 'turn in progress'

  const sendProgress = (summary: string): void => {
    if (stopped || progressInFlight) return

    progressInFlight = true
    void sendTurnProgress(sendEnvelope, active, summary).finally(() => {
      progressInFlight = false
    })
  }

  sendProgress('turn started')
  const timer = setInterval(() => {
    sendProgress(activitySummary)
  }, opts.intervalMs ?? turnProgressIntervalMs)
  timer.unref?.()

  return {
    touch: summary => {
      if (summary) activitySummary = summary
    },
    stop: () => {
      stopped = true
      clearInterval(timer)
    }
  }
}

/**
 * Sends one ephemeral turn-progress envelope and logs skipped sends.
 *
 * Backpressure is expected under load, so progress failure is recorded as
 * telemetry instead of turning a healthy in-flight turn into a durable failure.
 */
async function sendTurnProgress(sendEnvelope: EnvelopeSender, active: ActiveTurn, summary: string): Promise<void> {
  try {
    await sendEnvelope(workerProgressEnvelope(active.turnStart.turn, 'checkpoint', summary, active.correlationID))
  } catch (error) {
    workerLogger.warning('worker.turn_progress_skipped', 'worker turn progress skipped', {
      actor_event_id: active.turnStart.turn.actor_event_id,
      reason: isRuntimeFabricTransportError(error, 'backpressure') ? 'backpressure' : 'send_error',
      error: error instanceof Error ? error : new Error(String(error))
    })
  }
}

/**
 * Converts an arbitrary turn failure into durable details for the control plane.
 *
 * The worker does not decide final retry policy, but it preserves the LLM error
 * classification and AIGateway fields so the owner of the turn can make that
 * decision with more than a plain string.
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
 * error class.
 *
 * HTTP and WebSocket paths surface slightly different shapes; this helper keeps
 * the durable error JSON stable across both transports.
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

/**
 * Builds the worker-local key for the single active turn allowed per actor
 * activation and actor event.
 */
export function turnKey(turn: ActorTurnRef): string {
  return `${turn.activation_uid}:${turn.actor_event_id}`
}
