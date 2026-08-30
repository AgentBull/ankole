import { ms, type JsonObject as JSONObject } from '@agentbull/active-support'
import { errorMessage, toError } from '../common/errors'
import { turnAcceptedEnvelope, workerProgressEnvelope } from '../fabric/envelopes'
import { isRuntimeFabricTransportError, type EnvelopeSender } from '../fabric/fabric'
import type { Envelope } from '../fabric/envelope_proto'
import {
  mailboxUpdatedFromEnvelope,
  turnControlFromEnvelope,
  turnStartFromEnvelope,
  type ActorTurnRef,
  type TurnStart,
  type TurnSteerUpdate
} from '../lanes/actor_lane'
import { type RuntimeRPCClient } from '../lanes/rpc_lane'
import type { BrowserRuntime } from '../browser-runtime'
import type { WorkerConfig } from './config'
import type { WorkerDrainState } from './drain'
import { workerCapacityEnvelope } from './lifecycle_messages'
import { turnFailureLogError, workerLogger } from './logging'
import { abortTurnWithAck, TurnCompletionRejectedError, TurnTerminalRejectedError } from './turn_completion'
import { executeActiveTurn } from './turn_execution'
import { turnFailureDetails, turnFailureLogFields } from './turn_failure'

/** Cadence for best-effort progress checkpoints while a Turn is active. */
const turnProgressIntervalMs = ms('1m')

/**
 * Holds only the Worker-local state of one accepted Turn.
 * The control plane owns durable actor state and terminal state.
 */
export class ActiveTurn {
  private readonly steeringUpdates: TurnSteerUpdate[] = []
  private readonly steeringWaiters = new Set<() => void>()
  private readonly disabledSkillNames: string[] = []
  private readonly abortController = new AbortController()
  private stopRequested = false
  private stopCommand?: string
  private stopReason?: string

  constructor(
    readonly turnStart: TurnStart,
    readonly correlationID: string
  ) {}

  get abortSignal(): AbortSignal {
    return this.abortController.signal
  }

  get controlledStopRequested(): boolean {
    return this.stopRequested
  }

  get controlledStopCommand(): string | undefined {
    return this.stopCommand
  }

  get controlledStopReason(): string | undefined {
    return this.stopReason
  }

  /** Stores one journaled steer update and wakes foreground observers. */
  pushSteering(update: TurnSteerUpdate): void {
    this.steeringUpdates.push(update)
    // oxlint-disable-next-line unicorn/no-useless-spread
    for (const wake of [...this.steeringWaiters]) wake()
  }

  pollSteering(): TurnSteerUpdate[] {
    return this.steeringUpdates.splice(0)
  }

  /** Waits for steering without consuming an update already in the queue. */
  waitForSteering(signal?: AbortSignal): Promise<void> {
    if (this.steeringUpdates.length > 0) return Promise.resolve()
    if (signal?.aborted) return Promise.reject(abortReason(signal))

    return new Promise((resolve, reject) => {
      let settled = false

      const cleanup = (): void => {
        this.steeringWaiters.delete(steered)
        signal?.removeEventListener('abort', aborted)
      }
      const steered = (): void => {
        if (settled) return
        settled = true
        cleanup()
        resolve()
      }
      const aborted = (): void => {
        if (settled) return
        settled = true
        cleanup()
        reject(abortReason(signal))
      }

      this.steeringWaiters.add(steered)
      signal?.addEventListener('abort', aborted, { once: true })
    })
  }

  addDisabledSkills(skillNames: unknown): void {
    if (!Array.isArray(skillNames)) return
    for (const name of skillNames) {
      if (typeof name === 'string' && name.trim()) this.disabledSkillNames.push(name.trim())
    }
  }

  pollDisabledSkills(): string[] {
    return this.disabledSkillNames.splice(0)
  }

  requestControlledStop(command: string, reason: string): void {
    this.stopRequested = true
    this.stopCommand = command
    this.stopReason = reason
    this.abortController.abort(new DOMException(reason, 'AbortError'))
  }
}

/**
 * Owns the in-memory Turn set and its lifecycle: admission, controls, progress,
 * terminal acknowledgement, and capacity release. executeActiveTurn owns the
 * concrete execution surface.
 */
export class ActiveTurns {
  private readonly turns = new Map<string, ActiveTurn>()

  constructor(
    private readonly config: WorkerConfig,
    private readonly browserRuntime: BrowserRuntime,
    private readonly sendEnvelope: EnvelopeSender,
    private readonly rpcClient: RuntimeRPCClient,
    private readonly drain: WorkerDrainState
  ) {}

  get size(): number {
    return this.turns.size
  }

  get availableSlots(): number {
    return Math.max(this.config.maxConcurrentTurns - this.turns.size, 0)
  }

  publishCapacity(): Promise<void> {
    return this.sendEnvelope(workerCapacityEnvelope(this.config, this.availableSlots, this.turns.size))
  }

  /**
   * Accepts and launches one Turn if this Worker has capacity.
   *
   * The acceptance envelope is sent before the async task starts so the control
   * plane can fence duplicate deliveries and observe that this Worker took
   * responsibility for the actor event.
   */
  async start(envelope: Envelope): Promise<void> {
    const turnStart = turnStartFromEnvelope(envelope)
    const correlationID = envelope.messageId
    workerLogger.info('worker.turn_start_received', 'worker turn start received', {
      actor_event_id: turnStart.turn.actor_event_id,
      input_count: 1,
      operation: turnOperation(turnStart.turn.actor_event_id, { first: true })
    })

    const activeKey = turnKey(turnStart.turn)

    if (!this.drain.acceptsTurns) {
      await abortTurnWithAck(this.rpcClient, turnStart.turn, {
        code: 'worker_draining',
        message: 'worker is draining',
        details: { runtime: 'bun', retryable: true }
      })
      return
    }

    if (this.turns.has(activeKey)) {
      await abortTurnWithAck(this.rpcClient, turnStart.turn, {
        code: 'worker_busy',
        message: 'conversation already has an active turn',
        details: { runtime: 'bun', retryable: true }
      })
      return
    }

    if (this.turns.size >= this.config.maxConcurrentTurns) {
      await abortTurnWithAck(this.rpcClient, turnStart.turn, {
        code: 'worker_busy',
        message: 'worker has no available turn slots',
        details: {
          runtime: 'bun',
          retryable: true,
          active_turns: this.turns.size,
          max_turns: this.config.maxConcurrentTurns
        }
      })
      return
    }

    const active = new ActiveTurn(turnStart, correlationID)
    this.turns.set(activeKey, active)

    await this.sendEnvelope(turnAcceptedEnvelope(turnStart.turn, correlationID))
    await this.publishCapacity()

    this.drain.track(
      this.run(active).catch(error => {
        workerLogger.error('worker.turn_completion_error', 'worker turn completion task failed', {
          actor_event_id: turnStart.turn.actor_event_id,
          error: toError(error),
          operation: turnOperation(turnStart.turn.actor_event_id, { last: true })
        })
      })
    )
  }

  /**
   * Adds a journaled mailbox update to its matching active Turn.
   *
   * The Worker accepts only the ActorEvent already present in the mailbox
   * update. It does not synthesize steer text locally.
   */
  async mailboxUpdated(envelope: Envelope): Promise<void> {
    const update = mailboxUpdatedFromEnvelope(envelope)
    if (!update.turn) return

    const active = this.turns.get(turnKey(update.turn))
    if (!active) return

    active.pushSteering({
      turn: update.turn,
      actorEvent: update.actor_event,
      correlationID: envelope.messageId
    })
  }

  /**
   * Applies Skill disablement to active handlers. `retry` and `stop` cancel only
   * local execution. The control plane owns the next lifecycle decision, so this
   * path does not call actor_turn.abort.
   */
  async control(envelope: Envelope): Promise<void> {
    const control = turnControlFromEnvelope(envelope)
    if (!control.turn) return

    const active = this.turns.get(turnKey(control.turn))
    if (!active) return

    if (control.command === 'skill_disabled') {
      active.addDisabledSkills(control.payload_json?.skill_names)
      return
    }

    if (control.command !== 'retry' && control.command !== 'stop') return

    const reason = stringFromDetails(control.payload_json, 'reason') ?? control.command
    active.requestControlledStop(control.command, reason)
  }

  /**
   * Wraps execution with progress, failure reporting, and capacity release.
   * Complete, no-op, and failure paths wait for the terminal RPC response before
   * they remove local state. A semantic rejection is terminal. A controlled stop
   * sends no terminal RPC because the control plane owns the next decision.
   */
  private async run(active: ActiveTurn): Promise<void> {
    const turnStart = active.turnStart
    const startedAt = Date.now()
    const progress = startTurnProgress(this.sendEnvelope, active)

    try {
      await executeActiveTurn(
        this.config,
        this.browserRuntime,
        this.sendEnvelope,
        this.rpcClient,
        active,
        progress.touch
      )
      if (active.controlledStopRequested) {
        workerLogger.info('worker.turn_controlled_stop', 'worker turn controlled stop', {
          actor_event_id: turnStart.turn.actor_event_id,
          command: active.controlledStopCommand ?? 'unknown',
          reason: active.controlledStopReason ?? 'controlled_stop',
          duration_ms: Date.now() - startedAt,
          operation: turnOperation(turnStart.turn.actor_event_id, { last: true })
        })
        return
      }

      workerLogger.info('worker.turn_completed', 'worker turn completed', {
        actor_event_id: turnStart.turn.actor_event_id,
        duration_ms: Date.now() - startedAt,
        operation: turnOperation(turnStart.turn.actor_event_id, { last: true })
      })
    } catch (error) {
      if (active.controlledStopRequested) {
        workerLogger.info('worker.turn_controlled_stop', 'worker turn controlled stop', {
          actor_event_id: turnStart.turn.actor_event_id,
          command: active.controlledStopCommand ?? 'unknown',
          reason: active.controlledStopReason ?? 'controlled_stop',
          duration_ms: Date.now() - startedAt,
          error: turnFailureLogError(error),
          operation: turnOperation(turnStart.turn.actor_event_id, { last: true })
        })
        return
      }

      if (error instanceof TurnCompletionRejectedError || error instanceof TurnTerminalRejectedError) {
        workerLogger.error('worker.turn_completion_rejected', 'worker turn completion was rejected', {
          actor_event_id: turnStart.turn.actor_event_id,
          error: toError(error),
          operation: turnOperation(turnStart.turn.actor_event_id, { last: true })
        })
        throw error
      }

      const message = errorMessage(error)

      await abortTurnWithAck(
        this.rpcClient,
        turnStart.turn,
        {
          code: 'worker_turn_failed',
          message,
          details: turnFailureDetails(error)
        },
        {
          onRetry: (attempt, retryError) => {
            workerLogger.warning('worker.turn_abort_retry', 'worker turn abort acknowledgement missing', {
              actor_event_id: turnStart.turn.actor_event_id,
              attempt,
              error: toError(retryError)
            })
          }
        }
      )
      workerLogger.error('worker.turn_failed', 'worker turn failed', {
        actor_event_id: turnStart.turn.actor_event_id,
        duration_ms: Date.now() - startedAt,
        ...turnFailureLogFields(error),
        error: turnFailureLogError(error),
        operation: turnOperation(turnStart.turn.actor_event_id, { last: true })
      })
    } finally {
      progress.stop()
      this.turns.delete(turnKey(turnStart.turn))
      await this.publishCapacity()
    }
  }
}

/**
 * Starts periodic progress checkpoints for a Turn.
 *
 * Progress is best-effort and non-overlapping. A stuck progress send cannot
 * pile up timers or block the model and tool loop that it describes.
 */
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

type TurnProgressReporter = {
  touch: (summary?: string) => void
  stop: () => void
}

async function sendTurnProgress(sendEnvelope: EnvelopeSender, active: ActiveTurn, summary: string): Promise<void> {
  try {
    await sendEnvelope(workerProgressEnvelope(active.turnStart.turn, 'checkpoint', summary, active.correlationID))
  } catch (error) {
    workerLogger.warning('worker.turn_progress_skipped', 'worker turn progress skipped', {
      actor_event_id: active.turnStart.turn.actor_event_id,
      reason: isRuntimeFabricTransportError(error, 'backpressure') ? 'backpressure' : 'send_error',
      error: toError(error)
    })
  }
}

function abortReason(signal?: AbortSignal): Error {
  return signal?.reason instanceof Error ? signal.reason : new Error('Steering wait was aborted')
}

function stringFromDetails(source: JSONObject | undefined, key: string): string | undefined {
  const value = source?.[key]
  return typeof value === 'string' ? value : undefined
}

/** Keys one local Turn across mailbox revisions of the same actor event. */
function turnKey(turn: ActorTurnRef): string {
  return `${turn.activation_uid}:${turn.actor_event_id}`
}

function turnOperation(actorEventID: string, flags: { first?: boolean; last?: boolean } = {}): JSONObject {
  return {
    id: actorEventID,
    producer: 'ankole-worker/turn',
    ...flags
  }
}
