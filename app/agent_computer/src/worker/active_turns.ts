import { ms, type JsonObject as JSONObject } from '@agentbull/active-support'
import { errorMessage, toError } from '../common/errors'
import { turnAcceptedEnvelope, workerProgressEnvelope } from '../fabric/envelopes'
import { isRuntimeFabricTransportError, type EnvelopeSender } from '../fabric/fabric'
import type { Envelope } from '../fabric/envelope_proto'
import {
  mailboxUpdatedFromEnvelope,
  turnControlFromEnvelope,
  turnStartFromEnvelope,
  type JobTurnRef,
  type TurnStart,
  type TurnSteerUpdate
} from '../lanes/session_lane'
import { type RuntimeRPCClient } from '../lanes/rpc_lane'
import type { BrowserRuntime } from '../browser-runtime'
import type { WorkerConfig } from './config'
import type { WorkerDrainState } from './drain'
import type { Slots } from './lifecycle_messages'
import { workerLogger } from './logging'
import { abortTurnWithAck, TurnTerminalRejectedError, type TurnAbortFailure } from './turn_completion'
import { executeActiveTurn } from './turn_execution'
import { turnFailureDetails, turnFailureLogFields } from './turn_failure'

/** Cadence for best-effort progress checkpoints while a Turn is active. */
const turnProgressIntervalMs = ms('1m')

/**
 * Holds only the Worker-local state of one accepted Turn.
 * The control plane owns durable actor state and terminal state.
 */
export class ActiveTurn {
  private readonly steeringIDs = new Set<string>()
  private readonly steeringUpdates: TurnSteerUpdate[] = []
  private readonly disabledSkillNames: string[] = []
  private readonly abortController = new AbortController()
  acceptanceTask?: Promise<void>
  executionStarted = false
  private stopRequested = false
  private stopCommand?: string
  private stopReason?: string

  constructor(readonly turnStart: TurnStart) {}

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

  /** Stores each journaled steer update once. */
  pushSteering(update: TurnSteerUpdate): void {
    if (!update.signal || this.steeringIDs.has(update.signal.signal_id)) return
    this.steeringIDs.add(update.signal.signal_id)
    this.steeringUpdates.push(update)
  }

  pollSteering(): TurnSteerUpdate[] {
    return this.steeringUpdates.splice(0)
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
    private readonly drain: WorkerDrainState,
    private readonly slots: Slots
  ) {}

  get size(): number {
    return this.turns.size
  }

  /**
   * Accepts and launches one Turn if this Worker has capacity.
   *
   * The acceptance envelope is sent before the async task starts so the control
   * plane can fence duplicate deliveries and observe that this Worker took
   * responsibility for the Signal.
   */
  async start(envelope: Envelope): Promise<void> {
    const turnStart = turnStartFromEnvelope(envelope)
    workerLogger.info('worker.turn_start_received', 'worker turn start received', {
      signal_id: turnStart.turn.signal_id,
      input_count: 1,
      operation: turnOperation(turnStart.turn.signal_id, { first: true })
    })

    const activeKey = turnKey(turnStart.turn)

    const existing = this.turns.get(activeKey)
    if (existing) {
      this.confirm(existing)
      return
    }
    if (turnStart.mode === 'adopt') {
      this.reject(turnStart.turn, {
        code: 'job_attempt_unknown',
        message: 'Worker does not retain this Job attempt',
        details: { retryable: true, runtime: 'bun' }
      })
      return
    }

    if (!this.drain.acceptsTurns) {
      this.reject(turnStart.turn, {
        code: 'worker_draining',
        message: 'worker is draining',
        details: { runtime: 'bun', retryable: true }
      })
      return
    }

    if (!this.slots.reserve()) {
      this.reject(turnStart.turn, {
        code: 'worker_busy',
        message: 'worker has no available turn slots',
        details: {
          runtime: 'bun',
          retryable: true,
          active_slots: this.slots.used(),
          max_slots: this.config.maxConcurrentSlots
        }
      })
      return
    }

    const active = new ActiveTurn(turnStart)
    this.turns.set(activeKey, active)

    this.confirm(active)
  }

  /** Pending admission has no execution to drain; do not launch it after shutdown. */
  beginDrain(): void {
    for (const active of this.turns.values()) {
      if (!active.executionStarted) active.requestControlledStop('stop', 'worker_draining')
    }
  }

  private confirm(active: ActiveTurn): void {
    if (active.acceptanceTask || active.controlledStopRequested) return
    // Both fresh and duplicate deliveries share this task. The receive loop
    // stays available for controls and RPC replies while an ACK is uncertain.
    const task = this.confirmAndLaunch(active).finally(() => {
      active.acceptanceTask = undefined
    })
    active.acceptanceTask = task
    this.drain.track(
      task.catch(error => {
        workerLogger.error('worker.turn_acceptance_error', 'worker turn acceptance failed', {
          signal_id: active.turnStart.turn.signal_id,
          error: toError(error)
        })
      })
    )
  }

  private async confirmAndLaunch(active: ActiveTurn): Promise<void> {
    try {
      for (;;) {
        try {
          await this.sendEnvelope(turnAcceptedEnvelope(active.turnStart.turn), { signal: active.abortSignal })
          break
        } catch (error) {
          if (active.controlledStopRequested) return
          if (
            isRuntimeFabricTransportError(error, 'rejected') &&
            (error.reason === 'background_agent_job_attempt_changed' || error.reason === 'run_closed')
          ) {
            workerLogger.info('worker.turn_acceptance_rejected', 'control plane refused this Job attempt', {
              signal_id: active.turnStart.turn.signal_id,
              reason: error.reason
            })
            active.requestControlledStop('stop', error.reason)
            return
          }
          if (!isRuntimeFabricTransportError(error) || !error.retryable) throw error
          workerLogger.warning('worker.turn_acceptance_reconfirm', 'worker waits to confirm the same Job attempt', {
            signal_id: active.turnStart.turn.signal_id,
            reason: error.code
          })
          for (;;) {
            try {
              await this.rpcClient.awaitReady(active.abortSignal)
              break
            } catch (readyError) {
              if (active.controlledStopRequested) return
              if (!isRuntimeFabricTransportError(readyError, 'socket_closed')) throw readyError
            }
          }
        }
      }
      if (active.executionStarted || active.controlledStopRequested || !this.drain.acceptsTurns) return
      active.executionStarted = true
      // Capacity is already reserved and reported on rejoin. Publish it without
      // delaying execution on another replaceable heartbeat acknowledgement.
      this.drain.track(this.slots.publish())
      this.drain.track(
        this.run(active).catch(error => {
          workerLogger.error('worker.turn_completion_error', 'worker turn completion task failed', {
            signal_id: active.turnStart.turn.signal_id,
            error: toError(error),
            operation: turnOperation(active.turnStart.turn.signal_id, { last: true })
          })
        })
      )
    } catch (error) {
      if (active.controlledStopRequested) return
      if (active.executionStarted) {
        // A duplicate confirmation error cannot undo execution. Unexpected
        // errors remain visible; only an explicit invalid-attempt refusal stops it.
        throw error
      }
      await abortTurnWithAck(this.rpcClient, active.turnStart.turn, {
        code: 'worker_turn_failed',
        message: errorMessage(error),
        details: turnFailureDetails(error)
      })
      throw error
    } finally {
      if (!active.executionStarted) await this.release(active)
    }
  }

  private async release(active: ActiveTurn): Promise<void> {
    if (this.turns.get(turnKey(active.turnStart.turn)) !== active) return
    if (!active.controlledStopRequested) active.requestControlledStop('stop', 'turn_finished')
    this.turns.delete(turnKey(active.turnStart.turn))
    this.slots.release()
    await this.slots.publish()
  }

  private reject(turn: JobTurnRef, failure: TurnAbortFailure): void {
    // The receive loop must remain available for the terminal RPC reply.
    this.drain.track(
      abortTurnWithAck(this.rpcClient, turn, failure).catch(error => {
        workerLogger.error('worker.turn_rejection_error', 'worker turn rejection failed', {
          signal_id: turn.signal_id,
          error: toError(error)
        })
      })
    )
  }

  /**
   * Adds a journaled mailbox update to its matching active Turn.
   *
   * The Worker accepts only the Signal already present in the mailbox
   * update. It does not synthesize steer text locally.
   */
  async mailboxUpdated(envelope: Envelope): Promise<void> {
    const update = mailboxUpdatedFromEnvelope(envelope)
    if (!update.turn) return

    const active = this.turns.get(turnKey(update.turn))
    if (!active) return

    active.pushSteering({
      signal: update.signal
    })
  }

  /**
   * Applies Skill disablement to active handlers. `retry` and `stop` cancel only
   * local execution. The control plane owns the next lifecycle decision, so this
   * path does not call session_turn.abort.
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
      await executeActiveTurn(this.config, this.browserRuntime, this.rpcClient, active)
      if (active.controlledStopRequested) {
        workerLogger.info('worker.turn_controlled_stop', 'worker turn controlled stop', {
          signal_id: turnStart.turn.signal_id,
          command: active.controlledStopCommand ?? 'unknown',
          reason: active.controlledStopReason ?? 'controlled_stop',
          duration_ms: Date.now() - startedAt,
          operation: turnOperation(turnStart.turn.signal_id, { last: true })
        })
        return
      }

      workerLogger.info('worker.turn_completed', 'worker turn completed', {
        signal_id: turnStart.turn.signal_id,
        duration_ms: Date.now() - startedAt,
        operation: turnOperation(turnStart.turn.signal_id, { last: true })
      })
    } catch (error) {
      if (active.controlledStopRequested) {
        workerLogger.info('worker.turn_controlled_stop', 'worker turn controlled stop', {
          signal_id: turnStart.turn.signal_id,
          command: active.controlledStopCommand ?? 'unknown',
          reason: active.controlledStopReason ?? 'controlled_stop',
          duration_ms: Date.now() - startedAt,
          error: toError(error),
          operation: turnOperation(turnStart.turn.signal_id, { last: true })
        })
        return
      }

      if (error instanceof TurnTerminalRejectedError) {
        workerLogger.error('worker.turn_completion_rejected', 'worker turn completion was rejected', {
          signal_id: turnStart.turn.signal_id,
          error: toError(error),
          operation: turnOperation(turnStart.turn.signal_id, { last: true })
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
              signal_id: turnStart.turn.signal_id,
              attempt,
              error: toError(retryError)
            })
          }
        }
      )
      workerLogger.error('worker.turn_failed', 'worker turn failed', {
        signal_id: turnStart.turn.signal_id,
        duration_ms: Date.now() - startedAt,
        ...turnFailureLogFields(error),
        error: toError(error),
        operation: turnOperation(turnStart.turn.signal_id, { last: true })
      })
    } finally {
      progress.stop()
      await this.release(active)
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

  const sendProgress = (): void => {
    if (stopped || progressInFlight) return

    progressInFlight = true
    void sendTurnProgress(sendEnvelope, active).finally(() => {
      progressInFlight = false
    })
  }

  sendProgress()
  const timer = setInterval(() => {
    sendProgress()
  }, opts.intervalMs ?? turnProgressIntervalMs)
  timer.unref?.()

  return {
    stop: () => {
      stopped = true
      clearInterval(timer)
    }
  }
}

type TurnProgressReporter = {
  stop: () => void
}

async function sendTurnProgress(sendEnvelope: EnvelopeSender, active: ActiveTurn): Promise<void> {
  try {
    await sendEnvelope(workerProgressEnvelope(active.turnStart.turn))
  } catch (error) {
    workerLogger.warning('worker.turn_progress_skipped', 'worker turn progress skipped', {
      signal_id: active.turnStart.turn.signal_id,
      reason: isRuntimeFabricTransportError(error) ? error.code : 'send_error',
      error: toError(error)
    })
  }
}

function stringFromDetails(source: JSONObject | undefined, key: string): string | undefined {
  const value = source?.[key]
  return typeof value === 'string' ? value : undefined
}

/** Keys one local Turn across mailbox revisions of the same Signal. */
function turnKey(turn: JobTurnRef): string {
  return `${turn.job_id}:${turn.attempt}:${turn.signal_id}`
}

function turnOperation(signalID: string, flags: { first?: boolean; last?: boolean } = {}): JSONObject {
  return {
    id: signalID,
    producer: 'ankole-worker/turn',
    ...flags
  }
}
