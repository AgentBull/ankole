import { classifyLlmError } from '../core/llm-error-classifier'
import { workerProgressEnvelope } from '../fabric/envelopes'
import type { JsonObject } from '@pleisto/active-support'
import { isRuntimeFabricBackpressure, type ReliableEnvelopeSender } from '../fabric/sender'
import type { ActorTurnRef, TurnStart, TurnSteerUpdate } from '../lanes/actor_lane'
import type { WorkerConfig } from './config'
import { workerLogger } from './logging'

const turnProgressIntervalMs = 60_000

export type ActiveTurn = {
  turnStart: TurnStart
  correlationId: string
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
export function startTurnProgress(sendEnvelope: ReliableEnvelopeSender, active: ActiveTurn): () => void {
  let stopped = false
  let progressInFlight = false

  const sendProgress = (summary: string): void => {
    if (stopped || progressInFlight) return

    progressInFlight = true
    void sendTurnProgress(sendEnvelope, active, summary).finally(() => {
      progressInFlight = false
    })
  }

  sendProgress('turn started')
  const timer = setInterval(() => sendProgress('turn in progress'), turnProgressIntervalMs)
  timer.unref?.()

  return () => {
    stopped = true
    clearInterval(timer)
  }
}

/**
 * Sends one ephemeral turn-progress envelope and logs skipped sends.
 *
 * Backpressure is expected under load, so progress failure is recorded as
 * telemetry instead of turning a healthy in-flight turn into a durable failure.
 */
export async function sendTurnProgress(
  sendEnvelope: ReliableEnvelopeSender,
  active: ActiveTurn,
  summary: string
): Promise<void> {
  try {
    await sendEnvelope(workerProgressEnvelope(active.turnStart.turn, 'checkpoint', summary, active.correlationId))
  } catch (error) {
    workerLogger.warning('worker.turn_progress_skipped', 'worker turn progress skipped', {
      actor_event_id: active.turnStart.turn.actor_event_id,
      reason: isRuntimeFabricBackpressure(error) ? 'backpressure' : 'send_error',
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
export function turnFailureDetails(error: unknown): JsonObject {
  const classification = classifyLlmError(error)
  const details: JsonObject = {
    runtime: 'bun',
    llm_error_kind: classification.kind,
    retryable: classification.retryable,
    should_compress: classification.shouldCompress,
    should_fallback_provider: classification.shouldFallbackProvider
  }

  const gateway = aigatewayErrorDetails(error)
  if (gateway) details.aigateway = gateway

  return details
}

/**
 * Extracts structured AIGateway error fields without depending on one concrete
 * error class.
 *
 * HTTP and WebSocket paths surface slightly different shapes; this helper keeps
 * the durable error JSON stable across both transports.
 */
export function aigatewayErrorDetails(error: unknown): JsonObject | undefined {
  if (!error || typeof error !== 'object') return undefined

  const record = error as JsonObject
  const details: JsonObject = {}

  if (typeof record.code === 'string') details.code = record.code
  if (typeof record.status === 'number') details.status = record.status
  if (record.details && typeof record.details === 'object' && !Array.isArray(record.details)) {
    details.details_json = record.details as JsonObject
  }

  return Object.keys(details).length > 0 ? details : undefined
}

/**
 * Builds the worker-local key for the single active turn allowed per actor
 * activation and actor event.
 */
export function turnKey(turn: ActorTurnRef): string {
  return `${turn.activation_uid}:${turn.actor_event_id}`
}
